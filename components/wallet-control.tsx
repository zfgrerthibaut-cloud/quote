'use client';

import { Wallet } from 'lucide-react';
import { useAccount, useConnect, useDisconnect } from 'wagmi';

function shortAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function WalletControl() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected && address) {
    return (
      <button className="wallet-button" type="button" onClick={() => disconnect()}>
        <span className="wallet-dot" /> {shortAddress(address)}
      </button>
    );
  }

  return (
    <button
      className="wallet-button"
      type="button"
      disabled={isPending || connectors.length === 0}
      onClick={() => connectors[0] && connect({ connector: connectors[0] })}
    >
      <Wallet size={16} /> {isPending ? 'Connecting…' : 'Connect'}
    </button>
  );
}
