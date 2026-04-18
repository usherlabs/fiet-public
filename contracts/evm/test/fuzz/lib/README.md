# Runtime wrappers

`FuzzEntry` is the supported Medusa composition root for repo-owned fuzzing.

This directory is reserved for runtime wrapper contracts that replace legacy linked-library fuzz harnesses as they are
migrated into `FuzzEntry` modules. MMQ-01 does not need any wrappers because its harness is composed entirely with
ordinary `new` deployments.
