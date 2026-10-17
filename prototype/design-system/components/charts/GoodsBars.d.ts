import * as React from 'react';
/** Records "most valuable goods" ranking; leader solid yellow, rest 60%. */
export interface GoodsBarsProps { items: {label:string; value:number; display:string}[]; }
export declare function GoodsBars(props: GoodsBarsProps): JSX.Element;
