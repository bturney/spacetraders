import * as React from 'react';
/** Panel surface for every Mission Control block. */
export interface CardProps { tone?: string; inner?: boolean; children?: React.ReactNode; style?: React.CSSProperties; onClick?: () => void; }
export declare function Card(props: CardProps): JSX.Element;
