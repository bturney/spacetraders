import * as React from 'react';
/** "Ships in motion" for big fleets (100+): one cell per Ship, tinted by status, filled by progress, outlined when a sale lands. */
export interface FleetGridProps { ships: {name:string; status:'trading'|'busy'|'waiting'|'stuck'|'scouting'; progress:number; sold?:boolean}[]; columns?: number; onSelect?: (ship:any) => void; }
export declare function FleetGrid(props: FleetGridProps): JSX.Element;
