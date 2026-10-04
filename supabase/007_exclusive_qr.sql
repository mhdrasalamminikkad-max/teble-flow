-- Apply after 006_operations.sql. Preserves orders and bills; one active guest per visit.
begin;
alter table tableflow_pilot.guests add column if not exists revoked boolean not null default false;
-- Existing devices must scan again after this upgrade.
update tableflow_pilot.guests set revoked=true;
create or replace function public.tfp_claim_table(p_qr uuid,p_guest_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare t tableflow_pilot.tables;v tableflow_pilot.visits;g tableflow_pilot.guests;h bytea;
begin
 if p_guest_token is null or p_guest_token!~'^[a-f0-9]{64}$' then raise exception 'Invalid guest token';end if;
 select a.* into t from tableflow_pilot.tables a join tableflow_pilot.restaurants r on r.id=a.restaurant where a.qr=p_qr and a.enabled and r.active;
 if t.id is null then raise exception 'This table is unavailable';end if;
 select * into v from tableflow_pilot.visits where table_id=t.id and closed is null for update;
 if v.id is null then raise exception 'Ask staff to open your table first';end if;
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
create or replace function public.tfp_join(p_qr uuid,p_code text,p_guest_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog as $$begin raise exception 'Scan your table QR again. Visit codes are no longer used.';end$$;
create or replace function public.tfp_guest(p_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$
declare g tableflow_pilot.guests;
begin
 select * into g from tableflow_pilot.guests where token_hash=tableflow_pilot.hash(p_token);
 if g.token_hash is null then raise exception 'Please scan your table QR';end if;
 if g.revoked then raise exception 'TABLE_SESSION_REPLACED';end if;
 return tableflow_pilot.visit_json(g.visit);
end$$;
create or replace function public.tfp_order(p_token text,p_request uuid,p_items jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v tableflow_pilot.visits;t tableflow_pilot.tables;m tableflow_pilot.menu;i jsonb;items jsonb='[]';h bytea;o tableflow_pilot.orders;begin
 h=tableflow_pilot.hash(p_token);select x.* into v from tableflow_pilot.visits x join tableflow_pilot.guests g on g.visit=x.id where g.token_hash=h for update of x;
 if v.id is null then raise exception 'Please scan your table QR';end if;
 if exists(select 1 from tableflow_pilot.guests where token_hash=h and revoked) then raise exception 'TABLE_SESSION_REPLACED';end if;
 -- Return confirmed retries even if staff closed the visit after accepting the order.
 select * into o from tableflow_pilot.orders where guest_hash=h and request_id=p_request;if o.id is not null then return o.id;end if;
 if v.closed is not null then raise exception 'Your visit has ended';end if;
 if (select count(*) from tableflow_pilot.orders where visit=v.id)>=100 then raise exception 'This visit has reached its order limit. Ask staff for help.';end if;
 if exists(select 1 from tableflow_pilot.orders where guest_hash=h and created>clock_timestamp()-interval '2 seconds') then raise exception 'Please wait two seconds before sending another order';end if;
 select * into t from tableflow_pilot.tables where id=v.table_id;
 if not exists(select 1 from tableflow_pilot.restaurants where id=t.restaurant and active) then raise exception 'Restaurant unavailable';end if;
 if p_request is null or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'Invalid order';end if;
 if (select count(distinct j->>'id') from jsonb_array_elements(p_items) j)<>jsonb_array_length(p_items) then raise exception 'Each dish must appear only once per order';end if;
 for i in select * from jsonb_array_elements(p_items) loop
 if (i->>'qty') is null or (i->>'qty')!~'^[0-9]{1,2}$' or (i->>'qty')::integer not between 1 and 20 or length(coalesce(i->>'note',''))>200 then raise exception 'Invalid item quantity or note';end if;
 select * into m from tableflow_pilot.menu where id=(i->>'id')::uuid and restaurant=t.restaurant and available for share;
 if m.id is null then raise exception 'A dish is unavailable. Review your bag.';end if;
 if (i->>'price') is null or (i->>'price')::numeric<>m.price then raise exception 'A price changed. Review your bag.';end if;
 items=items||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price,'qty',(i->>'qty')::integer,'note',coalesce(i->>'note','')));
 end loop;
 insert into tableflow_pilot.orders(visit,guest_hash,request_id,items) values(v.id,h,p_request,items) returning id into o.id;perform tableflow_pilot.ping(t.restaurant);return o.id;end$$;
create or replace function public.tfp_guest_review(p_token text,p_rating integer,p_comment text) returns uuid
language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v uuid;r uuid;f uuid;h bytea;begin
 h=tableflow_pilot.hash(p_token);select visit into v from tableflow_pilot.guests where token_hash=h;
 if v is null or not exists(select 1 from tableflow_pilot.orders where visit=v) then raise exception 'Place an order before reviewing this visit';end if;
 perform 1 from tableflow_pilot.visits where id=v for update;
 if exists(select 1 from tableflow_pilot.guests where token_hash=h and revoked) then raise exception 'TABLE_SESSION_REPLACED';end if;
 if p_rating is null or p_rating not between 1 and 5 or p_comment is null or length(p_comment)>2000 then raise exception 'Choose 1–5 stars and keep feedback within 2000 characters';end if;
 select t.restaurant into r from tableflow_pilot.visits x join tableflow_pilot.tables t on t.id=x.table_id where x.id=v;
 insert into tableflow_pilot.feedback(id,restaurant,visit,guest_hash,source,rating,comment) values(gen_random_uuid(),r,v,h,'tableflow',p_rating,trim(p_comment))
 on conflict(visit,guest_hash) do update set rating=excluded.rating,comment=excluded.comment,status='open',resolution='',updated=now() returning id into f;return f;
end$$;
revoke all on function public.tfp_claim_table(uuid,text) from public;
grant execute on function public.tfp_claim_table(uuid,text) to anon,authenticated;
create or replace function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',4)$$;
commit;
