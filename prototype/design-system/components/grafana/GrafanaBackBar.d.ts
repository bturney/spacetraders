import * as React from 'react';
/** Return strip above a Grafana dashboard. */
export interface GrafanaBackBarProps { to?: string; url?: string; onBack?: () => void; }
export declare function GrafanaBackBar(props: GrafanaBackBarProps): JSX.Element;
