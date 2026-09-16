-- Fleet Chronicler - the exact queries behind every published count.
-- Kept in sync with chronicler/ledger.py in the fleet-chronicler repo.

-- 1. Work cycles: tasks completed on the UTC day (terminal = completed).
SELECT count(*) FROM tasks
WHERE status = 'completed'
  AND completed_at >= :day_start AND completed_at < :day_end;

-- 2. Root PRs merged into the root branch on the day (GitHub API, base
--    branch filter; merged_at within the day window).
--    GET /repos/{owner}/{repo}/pulls?state=closed&sort=updated

-- 3. Releases published on the day.
--    GET /repos/{owner}/{repo}/releases

-- 4. In-flight tasks (morning brief).
SELECT status, count(*) FROM tasks
WHERE status NOT IN ('completed', 'cancelled')
GROUP BY status;

-- 5. Awaiting CEO decision: open board-program cycles whose exploration
--    task is still non-terminal (the engine's own auto-close rule).
SELECT c.program_key, c.opened_at,
       c.items_proposed, c.items_approved, c.items_rejected
FROM board_program_cycles c
JOIN tasks t ON t.id = c.exploration_task_id
WHERE c.closed_at IS NULL
  AND t.status NOT IN ('completed', 'cancelled');

-- 6. Task ledger transitions on the day (active/idle detection).
SELECT event_type, count(DISTINCT target_id) FROM audit_log
WHERE event_type LIKE 'task.%'
  AND timestamp >= :day_start AND timestamp < :day_end
GROUP BY event_type;

-- 7. Board-program decisions on the day.
SELECT details->>'item_ref' AS item_ref,
       details->>'verdict' AS verdict
FROM audit_log
WHERE event_type = 'board_program.decision'
  AND timestamp >= :day_start AND timestamp < :day_end;

-- 8. Provider spend, rolling 7 days, grouped by provider. The usage
--    tables store only the raw model string, so the provider is derived
--    with the backend's MODEL_CATALOG heuristics (':cloud' wins first:
--    glm-5.3:cloud is Ollama Cloud, glm-5.3 is Z.ai direct). Costs are
--    the backend's estimated_cost_usd = usage attribution at published
--    API rates; subscription fixed fees are NOT in these numbers.
SELECT CASE
         WHEN model LIKE '%:cloud%' THEN 'ollama_cloud'
         WHEN model LIKE 'claude%' OR model LIKE '%opus%'
           OR model LIKE '%sonnet%' OR model LIKE '%haiku%' THEN 'anthropic'
         WHEN model LIKE 'glm%' THEN 'zai'
         WHEN model LIKE 'gpt-%' OR model LIKE '%codex%' THEN 'openai'
         WHEN model LIKE 'gemini%' THEN 'gemini'
         WHEN model LIKE 'grok%' THEN 'grok'
         WHEN model LIKE 'kimi%' THEN 'kimi'
         WHEN model LIKE 'nvidia/%' THEN 'nebius'
         WHEN model LIKE 'openrouter/%' THEN 'openrouter'
         WHEN model LIKE 'ollama/%' THEN 'local'
         ELSE 'other'
       END AS provider,
       SUM(total_cost_usd) AS cost_usd,
       SUM(session_count) AS sessions,
       SUM(tokens_input + tokens_output
           + tokens_cache_read + tokens_cache_write) AS tokens_total
FROM daily_usage_rollups
WHERE date >= :since
GROUP BY provider
ORDER BY cost_usd DESC, tokens_total DESC;

-- 9. Idle-cause classification (same signals as the backend's uptime
--    ledger). Zero heartbeats for a day = stack down; dispatch_paused
--    heartbeats or an unexpired maintenance_pause row = operator pause;
--    spawn failures / stalled tasks = up but failing.
SELECT count(*) FROM audit_log
WHERE event_type = 'dispatcher.alive'
  AND timestamp >= :day_start AND timestamp < :day_end;

SELECT count(*) FROM audit_log
WHERE event_type = 'dispatcher.alive'
  AND details->>'dispatch_paused' = 'true'
  AND timestamp >= :day_start AND timestamp < :day_end;

SELECT key, value FROM system_settings WHERE key LIKE 'maintenance_pause.%';

SELECT count(*) FROM audit_log
WHERE event_type = 'agent.spawn_failed'
  AND timestamp >= :day_start AND timestamp < :day_end;

SELECT count(*) FROM tasks
WHERE stalled_reason IS NOT NULL
  AND status NOT IN ('completed', 'cancelled');
