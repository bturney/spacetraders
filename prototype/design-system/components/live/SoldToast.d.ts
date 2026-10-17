import * as React from 'react';
/** Event pop-up when a sale lands. */
export interface SoldToastProps { amount: number; detail?: string; more?: number; visible?: boolean; }
export declare function SoldToast(props: SoldToastProps): JSX.Element;
