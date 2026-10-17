import * as React from 'react';
/** "What it compared" bars in the Ship Why card: chosen option green, alternatives muted, negatives red. */
export interface CompareBarsProps { options: {label:string; value:number; chosen?:boolean}[]; caption?: string; }
export declare function CompareBars(props: CompareBarsProps): JSX.Element;
