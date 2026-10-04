export function tableDestination(raw:string,origin:string){
 let url:URL;try{url=new URL(raw)}catch{return null}
 if(url.origin!==origin||url.pathname!=='/pilot'||url.username||url.password)return null;
 const qr=url.searchParams.get('qr');
 return qr&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(qr)?`/pilot?qr=${qr}`:null;
}
