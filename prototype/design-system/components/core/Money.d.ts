import * as React from 'react';
/** Signed credit amount. */
export interface MoneyProps { value: number|null; est?: boolean; stale?: boolean; size?: number; color?: string; }
export declare function Money(props: MoneyProps): JSX.Element;
