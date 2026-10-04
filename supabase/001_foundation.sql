-- TABLEFLOW database foundation. Not applied to a live project by this build.
-- Apply in a clean Supabase project, then provision users through Supabase Auth.
create extension if not exists pgcrypto;
create table public.restaurants (
 id uuid primary key default gen_random_uuid(), name text not null,
 slug text unique not null, active boolean not null default true,
 tax_rate numeric(5,2) not null default 5 check(tax_rate between 0 and 30),
 preparation_minutes integer not null default 20 check(preparation_minutes between 1 and 120),
 created_at timestamptz not null default now()
);
create table public.platform_admins(user_id uuid primary key references auth.users(id) on delete cascade);
create table public.memberships (
 restaurant_id uuid references public.restaurants(id) on delete cascade,
 user_id uuid references auth.users(id) on delete cascade,
 role text not null check(role in ('owner','manager','kitchen','waiter')),
 primary key(restaurant_id,user_id)
);
create table public.dining_tables (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 number integer not null check(number>0), qr_token uuid not null unique default gen_random_uuid(),
 enabled boolean not null default true, unique(restaurant_id,number), unique(id,restaurant_id)
);
create table public.menu_items (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 name text not null, description text not null default '', price numeric(10,2) not null check(price>0),
 category text not null, vegetarian boolean not null default false, available boolean not null default true,
 image_url text, unique(id,restaurant_id)
);
create table public.dining_sessions (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 table_id uuid not null, guest_token_hash bytea not null,
 opened_at timestamptz not null default now(), closed_at timestamptz,
 foreign key(table_id,restaurant_id) references public.dining_tables(id,restaurant_id),
 unique(id,restaurant_id)
);
-- A QR identifies a table; it does NOT reveal the active visit's bearer token.
create unique index one_open_visit_per_table on public.dining_sessions(table_id) where closed_at is null;
create table public.orders (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 session_id uuid not null, idempotency_key uuid not null unique,
 status text not null default 'Placed' check(status in ('Placed','Preparing','Ready','Served','Cancelled')),
 created_at timestamptz not null default now(),
 foreign key(session_id,restaurant_id) references public.dining_sessions(id,restaurant_id), unique(id,restaurant_id)
);
create table public.order_items (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 order_id uuid not null, menu_item_id uuid not null,
 name text not null, unit_price numeric(10,2) not null check(unit_price>0),
 quantity integer not null check(quantity between 1 and 20), note text not null default '' check(length(note)<=200),
 foreign key(order_id,restaurant_id) references public.orders(id,restaurant_id),
 foreign key(menu_item_id,restaurant_id) references public.menu_items(id,restaurant_id)
);
create table public.service_requests (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 session_id uuid not null, kind text not null check(kind in ('waiter','water','cutlery','allergy','bill')),
 completed_at timestamptz, created_at timestamptz not null default now(),
 foreign key(session_id,restaurant_id) references public.dining_sessions(id,restaurant_id)
);
create table public.subscriptions (
 restaurant_id uuid primary key references public.restaurants(id), plan text not null,
 billing_period text not null check(billing_period in ('monthly','yearly')),
 status text not null check(status in ('trial','active','past_due','cancelled')),
 price numeric(10,2) not null check(price>=0), renews_at timestamptz,
 provider_subscription_id text unique
);
create table public.restaurant_modules (
 restaurant_id uuid references public.restaurants(id), module text not null,
 enabled boolean not null default true, primary key(restaurant_id,module)
);
create table public.payment_events (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 provider_event_id text not null unique, amount numeric(12,2) not null check(amount>=0),
 currency text not null default 'INR', received_at timestamptz not null default now()
);
create function public.is_platform_admin() returns boolean language sql stable security definer
 set search_path=public,pg_temp as $$select exists(select 1 from public.platform_admins where user_id=auth.uid())$$;
create function public.restaurant_role(r uuid) returns text language sql stable security definer
 set search_path=public,pg_temp as $$select role from public.memberships where restaurant_id=r and user_id=auth.uid()$$;
revoke all on function public.is_platform_admin() from public;
revoke all on function public.restaurant_role(uuid) from public;
grant execute on function public.is_platform_admin(),public.restaurant_role(uuid) to authenticated;
alter table public.restaurants enable row level security;
alter table public.platform_admins enable row level security;
alter table public.memberships enable row level security;
alter table public.dining_tables enable row level security;
alter table public.menu_items enable row level security;
alter table public.dining_sessions enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.service_requests enable row level security;
alter table public.subscriptions enable row level security;
alter table public.restaurant_modules enable row level security;
alter table public.payment_events enable row level security;
create policy restaurant_read on public.restaurants for select to authenticated using(public.is_platform_admin() or public.restaurant_role(id) is not null);
create policy restaurant_admin on public.restaurants for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy restaurant_update on public.restaurants for update to authenticated using(public.restaurant_role(id) in ('owner','manager')) with check(public.restaurant_role(id) in ('owner','manager'));
create policy memberships_read on public.memberships for select to authenticated using(user_id=auth.uid() or public.is_platform_admin() or public.restaurant_role(restaurant_id) in ('owner','manager'));
create policy memberships_admin on public.memberships for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
-- No browser policy on platform_admins: elevation requires a trusted operator.
create policy tables_read on public.dining_tables for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy tables_manage on public.dining_tables for all to authenticated using(public.restaurant_role(restaurant_id) in ('owner','manager') or public.is_platform_admin()) with check(public.restaurant_role(restaurant_id) in ('owner','manager') or public.is_platform_admin());
create policy menu_read on public.menu_items for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy menu_manage on public.menu_items for all to authenticated using(public.restaurant_role(restaurant_id) in ('owner','manager') or public.is_platform_admin()) with check(public.restaurant_role(restaurant_id) in ('owner','manager') or public.is_platform_admin());
create policy session_staff_read on public.dining_sessions for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy orders_staff_read on public.orders for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy items_staff_read on public.order_items for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy requests_staff_read on public.service_requests for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy subscriptions_read on public.subscriptions for select to authenticated using(public.restaurant_role(restaurant_id) in ('owner','manager') or public.is_platform_admin());
create policy subscriptions_admin on public.subscriptions for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy modules_read on public.restaurant_modules for select to authenticated using(public.restaurant_role(restaurant_id) is not null or public.is_platform_admin());
create policy modules_admin on public.restaurant_modules for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
create policy payments_admin_read on public.payment_events for select to authenticated using(public.is_platform_admin());
-- Guest operations use narrowly scoped RPCs, not anonymous table access.
create function public.start_visit(p_qr uuid,p_guest_token text) returns uuid language plpgsql security definer
 set search_path=public,pg_temp as $$declare t public.dining_tables; s uuid; begin
 if length(p_guest_token)<40 or length(p_guest_token)>200 then raise exception 'Invalid guest token';end if;
 select * into t from public.dining_tables where qr_token=p_qr and enabled for update;
 if not found or not exists(select 1 from public.restaurants where id=t.restaurant_id and active) then raise exception 'Table unavailable';end if;
 select id into s from public.dining_sessions where table_id=t.id and closed_at is null and guest_token_hash=digest(p_guest_token,'sha256');
 if s is not null then return s;end if;
 if exists(select 1 from public.dining_sessions where table_id=t.id and closed_at is null) then raise exception 'Please ask staff to start your visit';end if;
 insert into public.dining_sessions(restaurant_id,table_id,guest_token_hash) values(t.restaurant_id,t.id,digest(p_guest_token,'sha256')) returning id into s;return s;end;$$;
create function public.place_guest_order(p_session uuid,p_guest_token text,p_key uuid,p_items jsonb) returns uuid language plpgsql security definer
 set search_path=public,pg_temp as $$declare s public.dining_sessions; o uuid; item jsonb; m public.menu_items; q integer; begin
 select * into s from public.dining_sessions where id=p_session and guest_token_hash=digest(p_guest_token,'sha256') and closed_at is null for update;
 if not found then raise exception 'Visit is not active';end if;
 if not exists(select 1 from public.restaurants where id=s.restaurant_id and active) then raise exception 'Restaurant unavailable';end if;
 select id into o from public.orders where idempotency_key=p_key and session_id=s.id;if o is not null then return o;end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>30 then raise exception 'Invalid order';end if;
 insert into public.orders(restaurant_id,session_id,idempotency_key) values(s.restaurant_id,s.id,p_key) returning id into o;
 for item in select * from jsonb_array_elements(p_items) loop
 select * into m from public.menu_items where id=(item->>'id')::uuid and restaurant_id=s.restaurant_id and available;
 if not found then raise exception 'Dish unavailable';end if;
 q=(item->>'quantity')::integer;
 if q is null or q<1 or q>20 then raise exception 'Invalid quantity';end if;
 insert into public.order_items(restaurant_id,order_id,menu_item_id,name,unit_price,quantity,note)
 values(s.restaurant_id,o,m.id,m.name,m.price,q,coalesce(item->>'note',''));
 end loop;return o;end;$$;
create function public.guest_visit(p_session uuid,p_guest_token text) returns jsonb language plpgsql security definer
 set search_path=public,pg_temp as $$declare s public.dining_sessions; result jsonb;begin
 select * into s from public.dining_sessions where id=p_session and guest_token_hash=digest(p_guest_token,'sha256');
 if not found then raise exception 'Visit not found';end if;
 select jsonb_build_object('id',s.id,'closed_at',s.closed_at,'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'status',o.status,'created_at',o.created_at,'items',(select jsonb_agg(jsonb_build_object('name',i.name,'unit_price',i.unit_price,'quantity',i.quantity,'note',i.note)) from public.order_items i where i.order_id=o.id))) from public.orders o where o.session_id=s.id),'[]'::jsonb)) into result;
 return result;end;$$;
create function public.set_order_status(p_order uuid,p_status text) returns void language plpgsql security definer
 set search_path=public,pg_temp as $$declare o public.orders; r text;begin
 select * into o from public.orders where id=p_order for update;if not found then raise exception 'Not found';end if;
 r=public.restaurant_role(o.restaurant_id);
 if not public.is_platform_admin() and coalesce(r,'') not in ('owner','manager','kitchen','waiter') then raise exception 'Forbidden';end if;
 if not ((o.status='Placed' and p_status='Preparing') or (o.status='Preparing' and p_status='Ready') or (o.status='Ready' and p_status='Served')) then raise exception 'Invalid transition';end if;
 if r='waiter' and p_status<>'Served' then raise exception 'Forbidden';end if;
 update public.orders set status=p_status where id=o.id;end;$$;
create function public.close_visit(p_session uuid) returns void language plpgsql security definer
 set search_path=public,pg_temp as $$declare s public.dining_sessions;begin
 select * into s from public.dining_sessions where id=p_session for update;
 if not found then raise exception 'Not found';end if;
 if not public.is_platform_admin() and coalesce(public.restaurant_role(s.restaurant_id),'') not in ('owner','manager') then raise exception 'Forbidden';end if;
 update public.dining_sessions set closed_at=now() where id=s.id and closed_at is null;
 update public.service_requests set completed_at=now() where session_id=s.id and completed_at is null;end;$$;
revoke all on function public.start_visit(uuid,text),public.place_guest_order(uuid,text,uuid,jsonb),public.guest_visit(uuid,text),public.set_order_status(uuid,text),public.close_visit(uuid) from public;
grant execute on function public.start_visit(uuid,text),public.place_guest_order(uuid,text,uuid,jsonb),public.guest_visit(uuid,text) to anon,authenticated;
grant execute on function public.set_order_status(uuid,text),public.close_visit(uuid) to authenticated;
-- Realtime is opt-in after tenant policy tests. Add only orders and service_requests
-- to supabase_realtime for authenticated staff. Never broadcast guest bearer tokens.
