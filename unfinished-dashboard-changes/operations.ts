export type Invoice={id:string;restaurant:string;name:string;kind:'monthly'|'setup';period:string;amount:number;paid:number;due:string};
export type Payment={id:string;invoice:string;name:string;amount:number;reference:string;created:string};
export type Review={id:string;restaurant:string;name:string;source:'tableflow'|'google';rating:number;comment:string;source_url:string;status:'open'|'in_progress'|'resolved';resolution:string;created:string};
export type StaffMember={id:string;username:string;role:string;active:boolean;self:boolean};
export type Table={id:string;number:number;enabled:boolean;qr:string;occupied:boolean};
export type Operations={invoices:Invoice[];payments:Payment[];reviews:Review[];tables:Table[];staff:StaffMember[];sales:{settled:number;unsettled:number;completed_visits:number}|null};
export type Restaurant={id:string;name:string;slug:string;active:boolean;tables:number;owner:string|null;contact:string|null;billing:string|null;monthly_amount:number|null;setup_amount:number|null};
export function outstanding(i:Invoice){return Math.max(0,Math.round((i.amount-i.paid)*100)/100)}
export function needsAttention(r:Review){return r.rating<=3&&r.status!=='resolved'}
export function billingTotals(data:Operations){return {received:Math.round(data.payments.reduce((s,p)=>s+p.amount,0)*100)/100,pending:Math.round(data.invoices.reduce((s,i)=>s+outstanding(i),0)*100)/100,flagged:data.reviews.filter(needsAttention).length}}
