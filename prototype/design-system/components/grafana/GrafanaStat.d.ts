import * as React from 'react';
/** Big-number stat body for a GrafanaPanel. */
export interface GrafanaStatProps { value: string; unit?: string; color?: string; sub?: string; }
export declare function GrafanaStat(props: GrafanaStatProps): JSX.Element;
