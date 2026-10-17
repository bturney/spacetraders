import * as React from 'react';
/** Fixed-width m:ss countdown with caption ("to arrival", "looks again", "next retry"). */
export interface CountdownProps { seconds: number|null; caption?: string; size?: number; color?: string; }
export declare function Countdown(props: CountdownProps): JSX.Element;
