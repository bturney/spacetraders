import * as React from 'react';
/** Journey bar between two waypoint codes with a glowing diamond marker. */
export interface RouteBarProps { from?: string; to?: string; progress?: number; color?: string; size?: 'sm'|'md'|'lg'; at?: string; }
export declare function RouteBar(props: RouteBarProps): JSX.Element;
