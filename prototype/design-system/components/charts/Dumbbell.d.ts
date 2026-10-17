import * as React from 'react';
/** Expected (hollow) vs actual (filled) for one trade, around a zero line. */
export interface DumbbellProps { label: string; expected: number; actual: number; note?: string; range?: number; }
export declare function Dumbbell(props: DumbbellProps): JSX.Element;
