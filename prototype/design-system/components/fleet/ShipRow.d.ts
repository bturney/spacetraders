import * as React from 'react';
/** One Ship in the fleet list: verb phrase, route, time, est. */
export interface ShipRowProps { ship: {name:string; status:'trading'|'busy'|'waiting'|'stuck'|'scouting'; phrase:string; from?:string; to?:string; at?:string; progress:number; time:string; timeCaption:string; expected:number|null; stale?:boolean}; compact?: boolean; sold?: number|null; onClick?: () => void; }
export declare function ShipRow(props: ShipRowProps): JSX.Element;
