# Proposal

Implement IMP-12 version-bound Run/Task scheduling, bounded concurrency, explicit dependencies, conflict handling, approved attempt dispatch and safe retries. Start with a pure FIFO scheduling decision over trusted task snapshots; add durable reservation and Runtime integration before exposing execution.
