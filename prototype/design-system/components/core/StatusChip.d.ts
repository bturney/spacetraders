import * as React from 'react';
/** Pill showing one of the five Ship statuses in game vocabulary. */
export interface StatusChipProps { status: 'trading'|'busy'|'waiting'|'stuck'|'scouting'; label?: string; small?: boolean; }
export declare function StatusChip(props: StatusChipProps): JSX.Element;
