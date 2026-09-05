---
name: test-environment
description: Admit the exact Pixelfed test or owner-runtime environment before T1/T2 execution and prevent lower-tier or incomplete readiness evidence from being promoted.
---

# Test environment admission

Use this Skill whenever a Pixelfed task proposes a test or runtime-dependent
command. It is a hard admission contract, not advisory setup guidance. The
current owner Issue, current Pixelfed CI, current source and the proven VinylHub
owner-runtime profile below define the admissible identities. A later current
Human-approved owner Issue may supersede the profile explicitly; upstream
defaults do not supersede it merely by moving.

## Select one validation tier

Classify the claim before selecting a command:

```text
T0 STATIC
  formatting, lint, syntax, static analysis or configuration inspection
  no runtime/service claim

T1 OWNER TEST
  the current native Pixelfed CI/unit/integration test environment

T2 OWNER RUNTIME / OWNER INTEGRATION
  the proven VinylHub Pixelfed owner Docker runtime needed by the claimed behavior

T3 APP COMPOSITION
  whole-environment composition or cross-owner Product integration
  NOT PIXELFED-OWNED
```

T0 may be used for bounded static evidence only. Do not describe a T0 result
as test, migration, service, worker, media or runtime evidence.

Pixelfed owns T1 and T2 evidence. Pixelfed may state exact owner requirements
and artifact identities for an App handoff, but T3 admission and composition
belong to `mirrorforce/vinyl-catalog-app`. A T3 topology must not silently
replace the owner T2 profile.

## Current VinylHub owner T2 Docker profile

Repeated accepted VinylHub owner-runtime deliveries converged on the Docker
profile below. Use it for current VinylHub `T2 OWNER RUNTIME / OWNER
INTEGRATION` unless a later current Human-approved owner Issue explicitly
requalifies and supersedes it.

### Exact source and application image

```text
SOURCE
  exact current Pixelfed task SHA/tree

APPLICATION IMAGE
  build the exact task source with the repository Dockerfile
  record the resulting immutable image digest

DOCKERFILE BASE
  serversideup/php:8.5-frankenphp@sha256:c8e9d95cd6b83180662f63de646937f3b304041ac4edfbd95ff8bd684467d035

PROVEN RUNTIME
  PHP 8.5.9
  required extensions/tooling include pdo_mysql, redis, gd/imagick/vips and FFmpeg
```

The resulting Pixelfed application-image digest is task-source specific; never
reuse a prior-lane image merely because its PHP base matches.

### Database and Redis

```text
DATABASE
  MySQL Community Server 8.4.12
  image = container-registry.oracle.com/mysql/community-server@sha256:7dcc4add9183664de3a214daf85a50c3ba6cccfd7534f700b6561bf5b41885be

REDIS
  image = redis@sha256:298e5b3bc566bade82f46ad5511777a4a07a294097ce16ada2f6a42be5239df5
  proven server = Redis 8.10.1
```

The upstream-native `docker-compose.yml` currently exposes a `mysql:9` service.
That service is **NOT ADMITTED for VinylHub T2** merely because it is the
upstream default. Do not patch migrations, switch database versions, or use
MySQL 9 to manufacture current VinylHub evidence unless a later Human-approved
owner requalification explicitly authorizes that transition.

Focused SQLite/Pest evidence may remain valid T1/unit evidence where the native
test suite uses it. SQLite never satisfies a MySQL migration/runtime T2 claim.

### Owner processes and runtime prerequisites

Start/admit only the owner processes material to the claim, while preserving
native Pixelfed lifecycle boundaries:

```text
Pixelfed web/API
Horizon            when queue/background behavior is material
scheduler          when scheduled behavior is material
shared storage     when media crosses web/worker/scheduler processes
Passport keys/client bootstrap when authenticated API behavior is material
FFmpeg/media toolchain when image/video behavior is material
```

For shared-storage claims, the accepted owner prerequisite is one shared
`/var/www/html/storage` lifecycle across the material Pixelfed processes. When
Passport is required, its key material is a protected runtime input under the
owner storage lifecycle; prove key readability and client/bootstrap readiness
without retaining private key bytes or credentials in evidence.

## Admit before execution

For every runtime-dependent T1/T2 command, complete the following record before
the first dependent command. Values must be exact, current and safe to retain;
do not record tokens, passwords, private keys, private endpoints or private
response bodies.

```text
ENVIRONMENT_ADMISSION = PASS | BLOCKED
VALIDATION_TIER        = T1 OWNER TEST | T2 OWNER RUNTIME / OWNER INTEGRATION
RUNNER_PLATFORM
RUNNER_IDENTITY
SOURCE_SHA
SOURCE_TREE
APPLICATION_IMAGE_IDENTITY
DEPENDENCY_IDENTITY
TEST_SOURCE_AVAILABLE
DEV_TEST_DEPS_AVAILABLE
CWD
CANONICAL_COMMAND
REQUIRED_SERVICES
SERVICE_IDENTITIES
SERVICE_HEALTH
DATABASE_MODE
MIGRATION_READINESS
QUEUE_WORKER_READINESS
SCHEDULER_READINESS
STORAGE_MOUNT_READINESS
PASSPORT_READINESS
MEDIA_TOOLCHAIN_READINESS
CREDENTIAL_PRECONDITIONS
```

Set `ENVIRONMENT_ADMISSION = PASS` only when every material field is proven and
every required service is ready. A service being started, an HTTP 200, a
successful process launch or exit code zero is not readiness evidence by
itself. Set admission to `BLOCKED` with the exact missing/mismatched field when
admission cannot be proven. Do not execute the dependent command merely to
rediscover a known mismatch.

## T1 — owner test admission

Fresh-read the current native Pixelfed CI workflow at execution time. Derive
the runner/runtime, test configuration, persistence shape, required services,
generated/bootstrap prerequisites, working directory and repository-native test
command it currently requires. Prove those requirements for the selected source
and dependencies; do not copy moving workflow state into durable guidance.

The admission record must prove, as applicable:

```text
workflow-selected runner/runtime identity
workflow-selected test configuration and setup
workflow-selected persistence/service identity and readiness
current source SHA/tree is the checked-out source
current lockfile and installed dependencies match that source
test source and required dev dependencies are present
workflow-required generated/bootstrap prerequisites are ready
workflow-selected working directory and canonical test command
```

T1 evidence remains T1. It cannot be represented as T2 MySQL owner-runtime,
migration, worker, storage, media or authenticated-API evidence.

## T2 — owner runtime/integration admission

Use the concrete VinylHub Docker profile above and exact current task source.
Before the first bounded owner-runtime/API proof, establish the material items
below in one claim-relevant environment:

```text
exact current source SHA/tree
exact current-source-built Pixelfed image digest
Dockerfile/base identity matches current source
MySQL 8.4.12 exact admitted image healthy and reachable
Redis exact admitted image healthy and reachable
fresh migration PASS
repeat migration PASS
upgrade migration PASS when a migration transition is material
application process + owner health/readiness PASS
Passport bootstrap/key readability/client readiness PASS when auth is material
Horizon/worker readiness PASS when queue behavior is material
scheduler readiness PASS when scheduled behavior is material
shared-storage cross-process canary PASS when media crosses processes
FFmpeg/codec/media tooling PASS when image/video behavior is claimed
credential/bootstrap preconditions PASS without retaining secret values
```

Use the smallest native readiness check for each material component: container
health plus actual DB connection, the real migration/state command, owner health,
Horizon/queue status, scheduler health, a cross-process storage canary, Passport
bootstrap/key read, or bounded media-processing/readback. Application HTTP
readiness never substitutes for migration, worker, scheduler, storage, Passport
or media readiness.

After a PASS, retain the disposable owner environment across adjacent focused
iterations where practical. Restart only the affected process/service and
re-admit if a material identity or readiness condition changes. Ordinary source
or business failures after valid admission are development evidence, not an
environment-admission failure.

## Mandatory hard vetoes

```text
upstream/native mysql:9 used as VinylHub T2 database authority
moving/latest/default image used as exact admitted T2 identity
prior-lane Pixelfed application image reused without exact current-source proof
T1 SQLite result represented as MySQL migration/runtime PASS
ad-hoc database/Redis/image version change after startup failure
application HTTP 200 represented as migration PASS
application HTTP 200 represented as Horizon/worker/scheduler/media/Passport PASS
container-local media file represented as cross-process shared-storage PASS
unavailable codec/FFmpeg/tooling represented as image/video PASS
missing Passport keys/client bootstrap represented as authenticated API PASS
App T3 composition represented as Pixelfed owner T2 without owner-equivalent proof
App harness failure represented as an owner source defect without owner-equivalent reproduction
secret/private key value retained in evidence
```

Use these bounded classifications when supported:

```text
PLATFORM_MISMATCH
RUNNER_NOT_ADMITTED
ARTIFACT_IDENTITY_MISMATCH
SERVICE_NOT_READY
SERVICE_HOST_INCOMPATIBLE
MIGRATION_NOT_READY
STORAGE_TOPOLOGY_NOT_READY
WORKER_OR_MEDIA_PREREQUISITE_NOT_READY
CREDENTIAL_PRECONDITION_MISSING
SOURCE_TEST_FAILURE
OWNER_RUNTIME_FAILURE
UNKNOWN
```

## Required handoff and evidence

For T3 or another owner boundary, stop the Pixelfed lane after recording the
exact T1/T2 requirements and identities that the App must compose. Do not call
that handoff a Pixelfed T3 PASS. For every T1/T2 claim retain:

```text
VALIDATION_TIER
ENVIRONMENT_ADMISSION
SOURCE_SHA / SOURCE_TREE
APPLICATION_IMAGE_IDENTITY
RUNNER_PLATFORM / RUNNER_IDENTITY
DEPENDENCY_IDENTITY
REQUIRED_SERVICES / SERVICE_IDENTITIES / SERVICE_HEALTH
DATABASE_MODE / MIGRATION_READINESS
QUEUE_WORKER_READINESS / SCHEDULER_READINESS
STORAGE_MOUNT_READINESS / PASSPORT_READINESS / MEDIA_TOOLCHAIN_READINESS
CWD / CANONICAL_COMMAND
PROOF_PERFORMED / OBSERVED_RESULT
AUTHORIZED_MUTATION
FORBIDDEN_SIDE_EFFECTS
PROTECTED_RESOURCES
UNKNOWN
DISPOSITION = PASS | BLOCKED | PARTIAL
```

If `ENVIRONMENT_ADMISSION = BLOCKED`, the dependent tier is `BLOCKED`, even if
an attempted command happened to exit successfully. Never claim a stronger tier
than the admitted environment supports.
