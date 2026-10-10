-- One-time cleanup for rows saved while names went through sanitize-html, which
-- stored "Tom & Jerry" as "Tom &amp; Jerry". Names are now stored as typed, so
-- this turns those entities back into plain characters.
--
-- Step 1 (read-only): count the affected rows.
-- Step 2: run the UPDATEs, only after the count has been reviewed.
--
-- "&amp;" is replaced last, so a value stored as "&amp;lt;" (the user typed
-- "&lt;") becomes "&lt;" rather than "<": each value is decoded exactly once.

-- Step 1: count affected rows

SELECT
     'Participants.name' as column_name
    ,COUNT(*) as affected_rows
FROM Participants as participants
WHERE participants.name ~ '&(amp|lt|gt|quot|#39);'
UNION ALL
SELECT
     'Participants.group_name'
    ,COUNT(*)
FROM Participants as participants
WHERE participants.group_name ~ '&(amp|lt|gt|quot|#39);'
UNION ALL
SELECT
     'Draws.organizer_name'
    ,COUNT(*)
FROM Draws as draws
WHERE draws.organizer_name ~ '&(amp|lt|gt|quot|#39);';

-- Step 2: decode, in one transaction

BEGIN;

UPDATE Participants as participants
SET name = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(participants.name, '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&#39;', ''''), '&amp;', '&')
WHERE participants.name ~ '&(amp|lt|gt|quot|#39);';

UPDATE Participants as participants
SET group_name = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(participants.group_name, '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&#39;', ''''), '&amp;', '&')
WHERE participants.group_name ~ '&(amp|lt|gt|quot|#39);';

UPDATE Draws as draws
SET organizer_name = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(draws.organizer_name, '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&#39;', ''''), '&amp;', '&')
WHERE draws.organizer_name ~ '&(amp|lt|gt|quot|#39);';

COMMIT;
