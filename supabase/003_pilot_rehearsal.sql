-- Run once AFTER 002_live_pilot.sql, as the trusted Supabase SQL editor operator.
-- Creates TEST data only. These are not the restaurant's real menu/prices.
-- Final results contain newly generated PINs. Save them privately; do not paste in chat.
begin;
create temporary table tfp_rehearsal_credentials on commit preserve rows as
with credentials as (
 select lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,10))::bit(40)::bigint)%10000000000)::text,10,'0') as manager_pin,
 lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,10))::bit(40)::bigint)%10000000000)::text,10,'0') as kitchen_pin
)
select tableflow_pilot.provision('TABLEFLOW rehearsal — TEST ORDERS ONLY','tableflow-rehearsal','manager',manager_pin) as restaurant_id,manager_pin,kitchen_pin from credentials;
insert into tableflow_pilot.staff(restaurant,username,pin_hash,role)
select restaurant_id,'kitchen',tableflow_pilot.pin_hash(kitchen_pin),'kitchen' from tfp_rehearsal_credentials;
insert into tableflow_pilot.menu(restaurant,name,description,price,category,veg,image)
select c.restaurant_id,m.name,'Rehearsal item. Do not prepare food for this ticket.',m.price,m.category,m.veg,m.image
from tfp_rehearsal_credentials c cross join (values
 ('TEST chicken biryani',249,'Test meals',false,'/food/biryani.jpg'),
 ('TEST grilled chicken',329,'Test meals',false,'/food/grill.jpg'),
 ('TEST mint lime',89,'Test drinks',true,'/food/lime.jpg')
) as m(name,price,category,veg,image);
commit;
select 'tableflow-rehearsal' as restaurant_code,'manager' as username,manager_pin as pin,'Manager: open and settle visits' as access from tfp_rehearsal_credentials
union all
select 'tableflow-rehearsal','kitchen',kitchen_pin,'Kitchen: update order preparation' from tfp_rehearsal_credentials;
