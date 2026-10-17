import * as React from 'react';
/** Plan health headline: one of four states plus a one-line reason. */
export interface HealthCardProps { state: 'on'|'setback'|'off'|'unknown'; reason: string; large?: boolean; }
export declare function HealthCard(props: HealthCardProps): JSX.Element;
