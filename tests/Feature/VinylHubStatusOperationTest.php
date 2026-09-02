<?php

use App\Models\Media;
use App\Models\Status;
use App\Models\User;
use App\Models\UserOidcMapping;
use App\Models\VinylHubStatusOperation;
use App\Services\VinylHubStatusOperationService;
use Illuminate\Database\Events\QueryExecuted;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Routing\Middleware\ThrottleRequests;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Queue;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->withoutMiddleware(ThrottleRequests::class);

    config([
        'cache.default' => 'array',
        'cache.limiter' => 'array',
        'vinylhub.account_edge.enabled' => true,
        'vinylhub.account_edge.service_token' => 'test-service-token',
    ]);

    Queue::fake();
});

function operationAccount(string $subject, string $username): User
{
    $user = User::factory()->create([
        'username' => $username,
        'email' => $username.'@community.invalid',
    ]);

    $user->refresh();
    UserOidcMapping::create([
        'user_id' => $user->id,
        'oidc_id' => $subject,
    ]);

    return $user;
}

function createOperationRequest($test, array $payload)
{
    return $test->withHeader('X-VinylHub-Service-Token', 'test-service-token')
        ->postJson('/api/v1/internal/vinylhub/status-operation/create', $payload);
}

function readOperationRequest($test, array $payload)
{
    return $test->withHeader('X-VinylHub-Service-Token', 'test-service-token')
        ->postJson('/api/v1/internal/vinylhub/status-operation/read', $payload);
}

it('requires the confidential service caller', function () {
    $subject = 'operation-auth-subject';
    operationAccount($subject, 'vhoperationauth');

    $this->postJson('/api/v1/internal/vinylhub/status-operation/read', [
        'external_subject' => $subject,
        'operation_key' => 'auth-key',
    ])->assertNotFound();
});

it('creates one durable accepted result and reuses it for the same user and key', function () {
    $subject = 'operation-repeat-subject';
    $user = operationAccount($subject, 'vhoperationrepeat');

    $first = createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'publication-001',
        'status' => 'First publication',
    ])->assertOk();

    $second = createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'publication-001',
        'status' => 'Changed payload is ignored after acceptance',
    ])->assertOk();

    expect($first->json('state'))->toBe('accepted');
    expect($first->json('accepted'))->toBeTrue();
    expect($second->json('status_id'))->toBe($first->json('status_id'));
    expect($second->json('status_url'))->toBe($first->json('status_url'));
    expect(Status::where('profile_id', $user->profile_id)->count())->toBe(1);
    expect(VinylHubStatusOperation::where('profile_id', $user->profile_id)->count())->toBe(1);
});

it('isolates the same key between different users', function () {
    $firstUser = operationAccount('operation-user-one', 'vhoperationone');
    $secondUser = operationAccount('operation-user-two', 'vhoperationtwo');

    $first = createOperationRequest($this, [
        'external_subject' => 'operation-user-one',
        'operation_key' => 'same-key',
        'status' => 'User one',
    ])->assertOk();
    $second = createOperationRequest($this, [
        'external_subject' => 'operation-user-two',
        'operation_key' => 'same-key',
        'status' => 'User two',
    ])->assertOk();

    expect($first->json('status_id'))->not->toBe($second->json('status_id'));
    expect(Status::whereIn('profile_id', [$firstUser->profile_id, $secondUser->profile_id])->count())->toBe(2);
    expect(VinylHubStatusOperation::where('operation_key', 'same-key')->count())->toBe(2);
});

it('converges when another writer wins the same-key race', function () {
    $subject = 'operation-race-subject';
    $user = operationAccount($subject, 'vhoperationrace');
    $injected = false;

    DB::listen(function (QueryExecuted $query) use (&$injected, $user) {
        if ($injected || ! str_contains(strtolower($query->sql), 'vinyl_hub_status_operations') || ! str_contains(strtolower($query->sql), 'select')) {
            return;
        }

        $injected = true;
        $status = Status::factory()->create([
            'profile_id' => $user->profile_id,
            'type' => 'text',
            'caption' => 'Winner',
        ]);

        VinylHubStatusOperation::create([
            'profile_id' => $user->profile_id,
            'operation_key' => 'race-key',
            'state' => VinylHubStatusOperation::STATE_ACCEPTED,
            'status_id' => $status->id,
            'status_url' => $status->url(),
        ]);
    });

    createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'race-key',
        'status' => 'Caller must converge',
    ])->assertOk()
        ->assertJsonPath('state', 'accepted')
        ->assertJsonPath('accepted', true);

    expect($injected)->toBeTrue();
    expect(Status::where('profile_id', $user->profile_id)->count())->toBe(1);
    expect(VinylHubStatusOperation::where('profile_id', $user->profile_id)->count())->toBe(1);
});

it('returns the accepted result after cache eviction and a fresh service instance', function () {
    $subject = 'operation-repair-subject';
    operationAccount($subject, 'vhoperationrepair');

    $created = createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'response-loss-key',
        'status' => 'Durably accepted',
    ])->assertOk();

    Cache::flush();
    app()->forgetInstance(VinylHubStatusOperationService::class);

    readOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'response-loss-key',
        'repair' => true,
    ])->assertOk()
        ->assertJsonPath('state', 'accepted')
        ->assertJsonPath('accepted', true)
        ->assertJsonPath('status_id', $created->json('status_id'))
        ->assertJsonPath('status_url', $created->json('status_url'));

    expect(Status::count())->toBe(1);
});

it('supports an uploaded media id and retains the operation result after native status deletion', function () {
    $subject = 'operation-media-subject';
    $user = operationAccount($subject, 'vhoperationmedia');
    $media = Media::create([
        'profile_id' => $user->profile_id,
        'user_id' => $user->id,
        'media_path' => 'testing/operation-image.jpg',
        'mime' => 'image/jpeg',
        'size' => 10,
    ]);

    $created = createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'media-key',
        'status' => 'Uploaded media',
        'media_ids' => [$media->id],
    ])->assertOk();

    $status = Status::findOrFail($created->json('status_id'));
    expect($status->type)->toBe('photo');
    expect($media->fresh()->status_id)->toBe($status->id);

    $status->delete();

    readOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'media-key',
    ])->assertOk()
        ->assertJsonPath('state', 'accepted')
        ->assertJsonPath('status_id', (string) $status->id);

    expect(Status::withTrashed()->where('profile_id', $user->profile_id)->count())->toBe(1);
});

it('reports an owner-proven no-effect key as retry-safe', function () {
    $subject = 'operation-no-effect-subject';
    operationAccount($subject, 'vhoperationnoeffect');

    readOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'never-created',
    ])->assertOk()
        ->assertJsonPath('state', 'no_effect')
        ->assertJsonPath('accepted', false)
        ->assertJsonPath('retry_safe', true)
        ->assertJsonPath('repairable', false);
});

it('preserves an explicit incomplete operation without blind retry', function () {
    $subject = 'operation-incomplete-subject';
    $user = operationAccount($subject, 'vhoperationincomplete');
    $other = User::factory()->create();
    $other->refresh();
    $foreignStatus = Status::factory()->create([
        'profile_id' => $other->profile_id,
        'caption' => 'Foreign status must not repair this operation',
    ]);

    VinylHubStatusOperation::create([
        'profile_id' => $user->profile_id,
        'operation_key' => 'incomplete-key',
        'state' => VinylHubStatusOperation::STATE_INCOMPLETE,
        'status_id' => $foreignStatus->id,
        'status_url' => $foreignStatus->url(),
    ]);

    readOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'incomplete-key',
        'repair' => true,
    ])->assertOk()
        ->assertJsonPath('state', 'incomplete')
        ->assertJsonPath('accepted', false)
        ->assertJsonPath('retry_safe', false)
        ->assertJsonPath('repairable', true);

    createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'incomplete-key',
        'status' => 'Must not duplicate',
    ])->assertOk()
        ->assertJsonPath('state', 'incomplete')
        ->assertJsonPath('accepted', false);

    expect(Status::where('profile_id', $user->profile_id)->count())->toBe(0);
});

it('rejects invalid fresh work without leaving an operation record', function () {
    $subject = 'operation-invalid-subject';
    $user = operationAccount($subject, 'vhoperationinvalid');

    createOperationRequest($this, [
        'external_subject' => $subject,
        'operation_key' => 'invalid-key',
    ])->assertStatus(422);

    expect(Status::where('profile_id', $user->profile_id)->count())->toBe(0);
    expect(VinylHubStatusOperation::where('profile_id', $user->profile_id)->count())->toBe(0);
});
