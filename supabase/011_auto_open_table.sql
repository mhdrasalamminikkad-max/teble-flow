begin;

-- Auto-open table on customer QR scan:
-- If no open visit exists on the table, automatically create one so guests can order immediately without staff intervention.
create or replace function public.tfp_claim_table(p_qr uuid,p_guest_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare
 t tableflow_pilot.tables;
 v tableflow_pilot.visits;
 g tableflow_pilot.guests;
 h bytea;
 new_code text;
begin
 if p_guest_token is null or p_guest_token!~'^[a-f0-9]{64}$' then raise exception 'Invalid guest token';end if;
 select a.* into t from tableflow_pilot.tables a join tableflow_pilot.restaurants r on r.id=a.restaurant where a.qr=p_qr and a.enabled and r.active;
 if t.id is null then raise exception 'This table is unavailable';end if;

 -- Find current open visit for this table
 select * into v from tableflow_pilot.visits where table_id=t.id and closed is null for update;
 
 -- If no active open visit exists, automatically create a fresh visit for the customer!
 if v.id is null then
  loop
   new_code=lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint)%100000000)::text,8,'0');
   exit when not exists(select 1 from tableflow_pilot.visits x where x.table_id=t.id and x.code=new_code);
  end loop;
  insert into tableflow_pilot.visits(table_id,code,tax)
  values(t.id,new_code,coalesce((select tax from tableflow_pilot.restaurants where id=t.restaurant),5))
  returning * into v;
 end if;

 h=tableflow_pilot.hash(p_guest_token);
 select * into g from tableflow_pilot.guests where token_hash=h;
 if g.token_hash is not null then
  if g.visit<>v.id or g.revoked then raise exception 'TABLE_SESSION_REPLACED';end if;
  return tableflow_pilot.visit_json(v.id);
 end if;

 update tableflow_pilot.guests set revoked=true where visit=v.id and not revoked;
 insert into tableflow_pilot.guests(token_hash,visit,revoked) values(h,v.id,false);
 perform tableflow_pilot.ping(t.restaurant);
 return tableflow_pilot.visit_json(v.id);
end$$;

revoke all on function public.tfp_claim_table(uuid,text) from public;
grant execute on function public.tfp_claim_table(uuid,text) to anon,authenticated;

create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',8)$$;

commit;
