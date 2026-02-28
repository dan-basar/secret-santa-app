export interface Participant {
  id?: number;
  name: string;
  email: string;
  group: string;
}

export interface Match {
  giver: Participant;
  receiver: Participant;
}

/**
 * Checks whether a valid matching is mathematically possible.
 * A valid matching requires that no single group holds more than floor(n/2)
 * participants when n is even, or floor(n/2) when n is odd — more precisely,
 * no group can have more members than the total number of people outside that group
 * (since each group member needs a receiver from outside the group,
 * and also needs to receive from outside the group).
 *
 * The exact condition: for a valid derangement-with-constraints to exist,
 * no group should account for more than half the participants (strictly more
 * than n/2 means it's impossible).
 */
export function isMatchingPossible(participants: Participant[]): {
  possible: boolean;
  reason?: string;
} {
  const n = participants.length;
  if (n < 2) {
    return { possible: false, reason: 'At least 2 participants are required.' };
  }

  // Count group sizes (only for named groups)
  const groupCounts: Record<string, number> = {};
  for (const p of participants) {
    const g = p.group.trim();
    if (g) {
      groupCounts[g] = (groupCounts[g] || 0) + 1;
    }
  }

  for (const [group, count] of Object.entries(groupCounts)) {
    if (count >= n) {
      return {
        possible: false,
        reason: `All participants are in group "${group}". No valid matches can be made.`,
      };
    }
    if (count > n / 2) {
      return {
        possible: false,
        reason: `Group "${group}" has too many members (${count} out of ${n}). A valid matching is impossible because there aren't enough people outside this group.`,
      };
    }
  }

  return { possible: true };
}

/**
 * Attempts to create a valid matching using a shuffle-and-verify approach
 * with backtracking fallback. Returns null if no valid matching found after
 * max attempts (should not happen if isMatchingPossible returns true).
 */
export function createMatches(participants: Participant[]): Match[] | null {
  const MAX_ATTEMPTS = 1000;

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const shuffled = [...participants].sort(() => Math.random() - 0.5);
    const result: Match[] = [];
    let valid = true;

    for (let i = 0; i < participants.length; i++) {
      const giver = participants[i];
      const receiver = shuffled[i];

      if (
        giver.name === receiver.name ||
        (giver.group.trim() &&
          receiver.group.trim() &&
          giver.group.trim().toLowerCase() === receiver.group.trim().toLowerCase())
      ) {
        valid = false;
        break;
      }

      result.push({ giver, receiver });
    }

    if (valid) return result;
  }

  // Fallback: deterministic backtracking
  return backtrackMatch(participants);
}

function backtrackMatch(
  participants: Participant[],
  index = 0,
  used = new Set<number>(),
  result: Match[] = []
): Match[] | null {
  if (index === participants.length) return result;

  const giver = participants[index];
  const indices = shuffle(
    Array.from({ length: participants.length }, (_, i) => i)
  );

  for (const ri of indices) {
    if (used.has(ri)) continue;
    const receiver = participants[ri];
    if (
      giver.name === receiver.name ||
      (giver.group.trim() &&
        receiver.group.trim() &&
        giver.group.trim().toLowerCase() ===
          receiver.group.trim().toLowerCase())
    )
      continue;

    used.add(ri);
    result.push({ giver, receiver });
    const sub = backtrackMatch(participants, index + 1, used, result);
    if (sub) return sub;
    used.delete(ri);
    result.pop();
  }

  return null;
}

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

