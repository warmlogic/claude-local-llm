## Configuration
Set `CACHE_TTL` in seconds (default 300). Setting it to 0 disables caching.
The `MAX_UPLOAD_MB` limit defaults to 25 and cannot exceed 100.
Retries use exponential backoff starting at 200 ms, capped at 5 attempts.
The service reads `config.yaml` from the working directory unless `CONFIG_PATH` is set.
