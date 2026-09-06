export type ChainBlock = Readonly<{
  number: bigint;
  hash: `0x${string}`;
  parentHash: `0x${string}`;
}>;

export type OrderedLog = Readonly<{
  blockNumber: bigint;
  transactionIndex: number;
  logIndex: number;
  transactionHash: `0x${string}`;
}>;

export function compareLogs(left: OrderedLog, right: OrderedLog) {
  if (left.blockNumber !== right.blockNumber) return left.blockNumber < right.blockNumber ? -1 : 1;
  if (left.transactionIndex !== right.transactionIndex) return left.transactionIndex - right.transactionIndex;
  if (left.logIndex !== right.logIndex) return left.logIndex - right.logIndex;
  return left.transactionHash.localeCompare(right.transactionHash);
}

export function dedupeLogs(logs: readonly OrderedLog[]) {
  const seen = new Set<string>();
  return [...logs].sort(compareLogs).filter((log) => {
    const key = `${log.blockNumber}:${log.transactionHash.toLowerCase()}:${log.logIndex}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function findCommonAncestor(
  canonical: readonly ChainBlock[],
  replacement: readonly ChainBlock[],
): ChainBlock | undefined {
  const canonicalByHash = new Map(canonical.map((block) => [block.hash.toLowerCase(), block]));
  for (const block of [...replacement].sort((a, b) => a.number > b.number ? -1 : 1)) {
    const match = canonicalByHash.get(block.hash.toLowerCase());
    if (match?.number === block.number) return match;
  }
  return undefined;
}

export function assertContiguous(blocks: readonly ChainBlock[], expectedParentHash?: `0x${string}`) {
  const ordered = [...blocks].sort((a, b) => a.number < b.number ? -1 : 1);
  for (let index = 0; index < ordered.length; index += 1) {
    const block = ordered[index];
    const previous = ordered[index - 1];
    if (previous && (block.number !== previous.number + 1n || block.parentHash.toLowerCase() !== previous.hash.toLowerCase())) {
      throw new Error('non_contiguous_chain');
    }
    if (!previous && expectedParentHash && block.parentHash.toLowerCase() !== expectedParentHash.toLowerCase()) {
      throw new Error('unexpected_parent');
    }
  }
  return ordered;
}

export function retryDelayMs(attempt: number, entropy = 0) {
  const boundedAttempt = Math.max(0, Math.min(attempt, 8));
  const jitter = Math.max(0, Math.min(entropy, 1));
  return Math.min(300_000, Math.round(1_000 * (2 ** boundedAttempt) * (0.8 + jitter * 0.4)));
}
