import * as React from 'react';
/** Generic dark dashboard panel for Grafana mocks. */
export interface GrafanaPanelProps { title: string; children?: React.ReactNode; noData?: boolean; style?: React.CSSProperties; }
export declare function GrafanaPanel(props: GrafanaPanelProps): JSX.Element;
