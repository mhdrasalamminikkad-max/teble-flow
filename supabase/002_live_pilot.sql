-- Standalone, opt-in pilot. Apply once in staging; independent of 001_foundation.sql.
-- No existing restaurant/demo records are modified. No default staff credentials.
begin;
create extension if not exists pgcrypto;
create schema tableflow_pilot;
revoke all on schema tableflow_pilot from public,anon,authenticated;
create table public.tfp_signals(id uuid primary key default gen_random_uuid(),revision bigint not null default 0);
alter table public.tfp_signals enable row level security;
revoke all on public.tfp_signals from public,anon,authenticated;
grant select on public.tfp_signals to anon,authenticated;
-- Signals contain ONLY an opaque random ID and revision; never orders or identities.
create policy tfp_signal_read on public.tfp_signals for select to anon,authenticated using(true);
create table tableflow_pilot.restaurants(id uuid primary key default gen_random_uuid(),slug text unique not null,name text not null,active boolean not null default true,tax numeric not null default 5 check(tax between 0 and 30),wait integer not null default 20,signal uuid not null references public.tfp_signals(id));
create table tableflow_pilot.staff(id uuid primary key default gen_random_uuid(),restaurant uuid not null references tableflow_pilot.restaurants(id),username text not null,pin_hash text not null,role text not null check(role in ('manager','kitchen','waiter')),active boolean not null default true,failures integer not null default 0,locked_until timestamptz,unique(restaurant,username));
create table tableflow_pilot.staff_sessions(token_hash bytea primary key,staff uuid not null references tableflow_pilot.staff(id),expires timestamptz not null default now()+interval '8 hours');
create table tableflow_pilot.tables(id uuid primary key default gen_random_uuid(),restaurant uuid not null references tableflow_pilot.restaurants(id),number integer not null check(number between 1 and 3),qr uuid not null unique default gen_random_uuid(),unique(restaurant,number));
create table tableflow_pilot.menu(id uuid primary key default gen_random_uuid(),restaurant uuid not null references tableflow_pilot.restaurants(id),name text not null,description text not null default '',price numeric(10,2) not null check(price>0),category text not null,veg boolean not null default false,image text not null default '',available boolean not null default true);
create table tableflow_pilot.visits(id uuid primary key default gen_random_uuid(),table_id uuid not null references tableflow_pilot.tables(id),code text not null,opened timestamptz not null default now(),closed timestamptz,failures integer not null default 0,locked_until timestamptz,tax numeric not null,unique(table_id,code));
create unique index tfp_one_open_visit on tableflow_pilot.visits(table_id) where closed is null;
create table tableflow_pilot.guests(token_hash bytea primary key,visit uuid not null references tableflow_pilot.visits(id));
create table tableflow_pilot.orders(id uuid primary key default gen_random_uuid(),visit uuid not null references tableflow_pilot.visits(id),guest_hash bytea not null references tableflow_pilot.guests(token_hash),request_id uuid not null,items jsonb not null,status text not null default 'Placed' check(status in ('Placed','Preparing','Ready','Served')),created timestamptz not null default now(),unique(guest_hash,request_id));
create index tfp_orders_visit on tableflow_pilot.orders(visit);
-- No direct access, even for authenticated clients. RPCs below enforce scope.
revoke all on all tables in schema tableflow_pilot from public,anon,authenticated;

create function tableflow_pilot.hash(t text) returns bytea language sql immutable set search_path=pg_catalog as $$select sha256(convert_to(t,'UTF8'))$$;
create function tableflow_pilot.token() returns text language sql volatile set search_path=pg_catalog as $$select replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','')$$;
-- Locate pgcrypto's actual schema (Supabase commonly uses extensions).
create function tableflow_pilot.pin_hash(pin text,salt text default null) returns text language plpgsql set search_path=pg_catalog as $$declare ns text;result text;begin
 select n.nspname into ns from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto';
 if salt is null then execute format('select %I.gen_salt(''bf'',10)',ns) into salt;end if;
 execute format('select %I.crypt($1,$2)',ns) into result using pin,salt;return result;end$$;
create function tableflow_pilot.actor(token text,roles text[] default array['manager','kitchen','waiter']) returns tableflow_pilot.staff language plpgsql set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;begin
 select a.* into s from tableflow_pilot.staff a join tableflow_pilot.staff_sessions b on b.staff=a.id join tableflow_pilot.restaurants r on r.id=a.restaurant where b.token_hash=tableflow_pilot.hash(token) and b.expires>now() and a.active and r.active;
 if s.id is null or not(s.role=any(roles)) then raise exception 'Please sign in with an authorized staff account' using errcode='42501';end if;return s;end$$;
create function tableflow_pilot.ping(r uuid) returns void language sql set search_path=pg_catalog,tableflow_pilot as $$update public.tfp_signals set revision=revision+1 where id=(select signal from tableflow_pilot.restaurants where id=r)$$;
create function tableflow_pilot.visit_json(v uuid) returns jsonb language sql stable set search_path=pg_catalog,tableflow_pilot as $$
 select jsonb_build_object('id',x.id,'table',t.number,'closed',x.closed,'tax',x.tax,'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'status',o.status,'items',o.items,'created',o.created) order by o.created desc) from tableflow_pilot.orders o where o.visit=x.id),'[]'::jsonb)) from tableflow_pilot.visits x join tableflow_pilot.tables t on t.id=x.table_id where x.id=v$$;

create function public.tfp_health() returns jsonb language sql security definer set search_path=pg_catalog as $$select jsonb_build_object('version',1)$$;
revoke all on function public.tfp_health() from public;
grant execute on function public.tfp_health() to anon,authenticated;
create function public.tfp_menu(p_qr uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare t tableflow_pilot.tables;r tableflow_pilot.restaurants;begin
 select * into t from tableflow_pilot.tables where qr=p_qr;select * into r from tableflow_pilot.restaurants where id=t.restaurant and active;
 if r.id is null then raise exception 'This table is unavailable';end if;
 return jsonb_build_object('name',r.name,'restaurant',r.id,'table',t.number,'wait',r.wait,'signal',r.signal,'dishes',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'description',m.description,'price',m.price,'category',m.category,'veg',m.veg,'image',m.image,'available',m.available) order by m.category,m.name) from tableflow_pilot.menu m where m.restaurant=r.id),'[]'::jsonb));end$$;
create function public.tfp_login(p_slug text,p_username text,p_pin text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t text;begin
 select a.* into s from tableflow_pilot.staff a join tableflow_pilot.restaurants r on r.id=a.restaurant where r.slug=p_slug and r.active and a.username=p_username and a.active for update of a;
 if s.id is null then return jsonb_build_object('error','Username or PIN is incorrect');end if;
 if s.locked_until>now() then return jsonb_build_object('error','Too many attempts. Try again in five minutes.');end if;
 if p_pin is null or p_pin!~'^[0-9]{6,12}$' or tableflow_pilot.pin_hash(p_pin,s.pin_hash)<>s.pin_hash then
 update tableflow_pilot.staff set failures=case when failures>=4 then 0 else failures+1 end,locked_until=case when failures>=4 then now()+interval '5 minutes' else null end where id=s.id;
 return jsonb_build_object('error','Username or PIN is incorrect');end if;
 update tableflow_pilot.staff set failures=0,locked_until=null where id=s.id;
 delete from tableflow_pilot.staff_sessions where expires<now();
 t=tableflow_pilot.token();insert into tableflow_pilot.staff_sessions(token_hash,staff) values(tableflow_pilot.hash(t),s.id);
 return jsonb_build_object('token',t,'role',s.role,'username',s.username);end$$;
create function public.tfp_logout(p_token text) returns void language sql security definer set search_path=pg_catalog,tableflow_pilot as $$delete from tableflow_pilot.staff_sessions where token_hash=tableflow_pilot.hash(p_token)$$;
create function public.tfp_staff(p_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;r tableflow_pilot.restaurants;begin
 s=tableflow_pilot.actor(p_token);select * into r from tableflow_pilot.restaurants where id=s.restaurant;
 return jsonb_build_object('name',r.name,'role',s.role,'signal',r.signal,'tables',(select jsonb_agg(jsonb_build_object('id',t.id,'number',t.number,'qr',t.qr,'visit',(select jsonb_build_object('id',v.id,'code',case when s.role in ('manager','waiter') then v.code else null end) from tableflow_pilot.visits v where v.table_id=t.id and v.closed is null)) order by t.number) from tableflow_pilot.tables t where t.restaurant=r.id),'visits',coalesce((select jsonb_agg(tableflow_pilot.visit_json(v.id) order by v.opened desc) from tableflow_pilot.visits v join tableflow_pilot.tables t on t.id=v.table_id where t.restaurant=r.id and (v.closed is null or v.closed>now()-interval '1 day')),'[]'::jsonb));end$$;
create function public.tfp_open(p_token text,p_table uuid) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;t tableflow_pilot.tables;v uuid;new_code text;begin
 s=tableflow_pilot.actor(p_token,array['manager','waiter']);select * into t from tableflow_pilot.tables where id=p_table and restaurant=s.restaurant for update;
 if t.id is null then raise exception 'Table unavailable';end if;
 select id into v from tableflow_pilot.visits where table_id=t.id and closed is null;if v is not null then return v;end if;
 loop
 new_code=lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint)%100000000)::text,8,'0');
 exit when not exists(select 1 from tableflow_pilot.visits x where x.table_id=t.id and x.code=new_code);
 end loop;
 insert into tableflow_pilot.visits(table_id,code,tax) values(t.id,new_code,(select tax from tableflow_pilot.restaurants where id=s.restaurant)) returning id into v;perform tableflow_pilot.ping(s.restaurant);return v;end$$;
create function public.tfp_join(p_qr uuid,p_code text,p_guest_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v tableflow_pilot.visits;t tableflow_pilot.tables;h bytea;begin
 if p_guest_token is null or p_guest_token!~'^[a-f0-9]{64}$' then raise exception 'Invalid guest token';end if;
 select a.* into t from tableflow_pilot.tables a join tableflow_pilot.restaurants r on r.id=a.restaurant where a.qr=p_qr and r.active;
 select * into v from tableflow_pilot.visits where table_id=t.id and closed is null for update;
 if v.id is null then return jsonb_build_object('error','Ask staff to open your table visit.');end if;
 h=tableflow_pilot.hash(p_guest_token);
 if exists(select 1 from tableflow_pilot.guests where token_hash=h and visit=v.id) then return tableflow_pilot.visit_json(v.id);end if;
 if v.locked_until>now() then return jsonb_build_object('error','Please wait a minute and ask staff to confirm your visit code.');end if;
 if p_code is distinct from v.code then
 update tableflow_pilot.visits set failures=case when failures>=9 then 0 else failures+1 end,locked_until=case when failures>=9 then now()+interval '1 minute' else null end where id=v.id;
 return jsonb_build_object('error','Visit code is incorrect. Ask your waiter.');end if;
 if (select count(*) from tableflow_pilot.guests where visit=v.id)>=16 then return jsonb_build_object('error','This visit has reached its device limit. Ask staff for help.');end if;
 insert into tableflow_pilot.guests values(h,v.id);return tableflow_pilot.visit_json(v.id);end$$;
create function public.tfp_guest(p_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v uuid;begin
 select visit into v from tableflow_pilot.guests where token_hash=tableflow_pilot.hash(p_token);if v is null then raise exception 'Please join your table visit';end if;return tableflow_pilot.visit_json(v);end$$;
create function public.tfp_order(p_token text,p_request uuid,p_items jsonb) returns uuid language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare v tableflow_pilot.visits;t tableflow_pilot.tables;m tableflow_pilot.menu;i jsonb;items jsonb='[]';h bytea;o tableflow_pilot.orders;begin
 h=tableflow_pilot.hash(p_token);select x.* into v from tableflow_pilot.visits x join tableflow_pilot.guests g on g.visit=x.id where g.token_hash=h for update of x;
 if v.id is null then raise exception 'Please join your table visit';end if;
 -- Return confirmed retries even if staff closed the visit after accepting the order.
 select * into o from tableflow_pilot.orders where guest_hash=h and request_id=p_request;if o.id is not null then return o.id;end if;
 if v.closed is not null then raise exception 'Your visit has ended';end if;
 if (select count(*) from tableflow_pilot.orders where visit=v.id)>=100 then raise exception 'This visit has reached its order limit. Ask staff for help.';end if;
 if exists(select 1 from tableflow_pilot.orders where guest_hash=h and created>clock_timestamp()-interval '2 seconds') then raise exception 'Please wait two seconds before sending another order';end if;
 select * into t from tableflow_pilot.tables where id=v.table_id;
 if not exists(select 1 from tableflow_pilot.restaurants where id=t.restaurant and active) then raise exception 'Restaurant unavailable';end if;
 if p_request is null or p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 30 then raise exception 'Invalid order';end if;
 for i in select * from jsonb_array_elements(p_items) loop
 if (i->>'qty') is null or (i->>'qty')!~'^[0-9]{1,2}$' or (i->>'qty')::integer not between 1 and 20 or length(coalesce(i->>'note',''))>200 then raise exception 'Invalid item quantity or note';end if;
 select * into m from tableflow_pilot.menu where id=(i->>'id')::uuid and restaurant=t.restaurant and available for share;
 if m.id is null then raise exception 'A dish is unavailable. Review your bag.';end if;
 if (i->>'price') is null or (i->>'price')::numeric<>m.price then raise exception 'A price changed. Review your bag.';end if;
 items=items||jsonb_build_array(jsonb_build_object('id',m.id,'name',m.name,'price',m.price,'qty',(i->>'qty')::integer,'note',coalesce(i->>'note','')));
 end loop;
 insert into tableflow_pilot.orders(visit,guest_hash,request_id,items) values(v.id,h,p_request,items) returning id into o.id;perform tableflow_pilot.ping(t.restaurant);return o.id;end$$;
create function public.tfp_status(p_token text,p_order uuid,p_status text) returns void language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;o tableflow_pilot.orders;begin
 s=tableflow_pilot.actor(p_token);select a.* into o from tableflow_pilot.orders a join tableflow_pilot.visits v on v.id=a.visit join tableflow_pilot.tables t on t.id=v.table_id where a.id=p_order and t.restaurant=s.restaurant for update of a;
 if o.id is null then raise exception 'Order unavailable';end if;
 if o.status=p_status then return;end if;
 if s.role='waiter' and p_status<>'Served' then raise exception 'Not permitted';end if;
 if not((o.status='Placed' and p_status='Preparing') or (o.status='Preparing' and p_status='Ready') or (o.status='Ready' and p_status='Served')) then raise exception 'Order status changed. Refresh and try again.';end if;
 update tableflow_pilot.orders set status=p_status where id=o.id;perform tableflow_pilot.ping(s.restaurant);end$$;
create function public.tfp_close(p_token text,p_visit uuid) returns void language plpgsql security definer set search_path=pg_catalog,tableflow_pilot as $$declare s tableflow_pilot.staff;v tableflow_pilot.visits;begin
 s=tableflow_pilot.actor(p_token,array['manager']);select a.* into v from tableflow_pilot.visits a join tableflow_pilot.tables t on t.id=a.table_id where a.id=p_visit and t.restaurant=s.restaurant for update of a;
 if v.id is null then raise exception 'Visit unavailable';end if;
 if exists(select 1 from tableflow_pilot.orders where visit=v.id and status<>'Served') then raise exception 'Serve all orders before settling this visit';end if;
 update tableflow_pilot.visits set closed=coalesce(closed,now()) where id=v.id;perform tableflow_pilot.ping(s.restaurant);end$$;
-- Trusted SQL operator only. Never expose provisioning through anonymous RPCs.
create function tableflow_pilot.provision(p_name text,p_slug text,p_user text,p_pin text) returns uuid language plpgsql set search_path=pg_catalog,tableflow_pilot as $$declare r uuid;signal uuid;begin
 if p_pin is null or p_pin!~'^[0-9]{8,12}$' or length(p_name)<1 or p_slug!~'^[a-z0-9-]{3,40}$' or length(p_user)<1 then raise exception 'Use a restaurant name, slug, username and an 8–12 digit PIN';end if;
 insert into public.tfp_signals default values returning id into signal;
 insert into tableflow_pilot.restaurants(name,slug,signal) values(p_name,p_slug,signal) returning id into r;
 insert into tableflow_pilot.staff(restaurant,username,pin_hash,role) values(r,p_user,tableflow_pilot.pin_hash(p_pin),'manager');
 insert into tableflow_pilot.tables(restaurant,number) select r,n from generate_series(1,3) n;return r;end$$;
revoke all on all functions in schema tableflow_pilot from public,anon,authenticated;
revoke all on function public.tfp_menu(uuid),public.tfp_login(text,text,text),public.tfp_logout(text),public.tfp_staff(text),public.tfp_open(text,uuid),public.tfp_join(uuid,text,text),public.tfp_guest(text),public.tfp_order(text,uuid,jsonb),public.tfp_status(text,uuid,text),public.tfp_close(text,uuid) from public;
grant execute on function public.tfp_menu(uuid),public.tfp_login(text,text,text),public.tfp_logout(text),public.tfp_staff(text),public.tfp_open(text,uuid),public.tfp_join(uuid,text,text),public.tfp_guest(text),public.tfp_order(text,uuid,jsonb),public.tfp_status(text,uuid,text),public.tfp_close(text,uuid) to anon,authenticated;
do $$begin if exists(select 1 from pg_publication where pubname='supabase_realtime') then alter publication supabase_realtime add table public.tfp_signals;end if;end$$;
commit;
