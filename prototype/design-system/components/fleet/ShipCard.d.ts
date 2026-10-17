import * as React from 'react';
/** "Ships in motion" card for small fleets (≤ ~6): big countdown + route bar. */
export interface ShipCardProps { ship: {name:string; status:'trading'|'busy'|'waiting'|'stuck'|'scouting'; phrase:string; from?:string; to?:string; at?:string; progress:number; seconds:number|null; timeCaption:string}; sold?: number|null; onClick?: () => void; }
export declare function ShipCard(props: ShipCardProps): JSX.Element;
