import {env} from 'cloudflare:workers';
export const dynamic='force-dynamic';
export async function GET(){
 const vars=env as unknown as Record<string,unknown>;
 const url=String(vars.SUPABASE_URL||'').trim();
 const key=String(vars.SUPABASE_PUBLISHABLE_KEY||'').trim();
 // Only a publishable key is ever shipped. Secret/service-role credentials are rejected.
 const keyPresent=key.startsWith('sb_publishable_');let version=0,databaseReady=false,setupMessage='Pilot database setup is still required.';
 if(!url)setupMessage='Sign-in is not set up: the Supabase project URL is missing.';
 else if(!keyPresent)setupMessage='Sign-in is not set up: the Supabase publishable key is missing or invalid.';
 if(keyPresent){try{const response=await fetch(`${url}/rest/v1/rpc/tfp_health`,{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:'{}',signal:AbortSignal.timeout(6000)});const result=await response.json() as {version?:number};version=Number(result.version)||0;databaseReady=response.ok&&version>=1;if(databaseReady)setupMessage='Pilot database is reachable.';else if(response.status===401||response.status===403)setupMessage='The project rejected the key. Check its API key configuration.';}catch{setupMessage='Could not reach the project. Retry after checking the connection.'}}
 return Response.json({url,publishableKey:keyPresent?key:'',configured:keyPresent&&databaseReady,version,keyPresent,databaseReady,setupMessage},{headers:{'Cache-Control':'no-store'}});
}
