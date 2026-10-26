-- date clean up -- 
update events 
	SET 
		event_type = LOWER(event_type),
		traffic_source = LOWER(traffic_source),
		device_type = LOWER(device_type),
		page_category = LOWER(page_category);
update transactions 
	set
		timestamp = cast(timestamp as timestamp);
-- look for duplicates --

select 
	customer_id,
	event_type,
	timestamp,
	count(*) as duplicate_count
from events ee
group by
	customer_id,
	event_type,
	timestamp
having count(*) > 1;

-- finding the change over time --

create view change_over_time as 
select
	date_trunc('month', timestamp::timestamp) as order_date,
	sum(gross_revenue) as total_sales,
	count(distinct customer_id) as total_cutomers,
	sum(quantity) as total_quantity
from transactions tt
where timestamp is not null
group by order_date
order by order_date;

-- cumulative analysis --

with moving_avg_cte as (
select 
	date_trunc('month', timestamp::timestamp) as order_date,
	sum(gross_revenue) as total_sales,
	avg(gross_revenue) as avg_revenue
from transactions t
where timestamp is not null
group by order_date
order by order_date
)

select
	order_date,
	total_sales,
	SUM(total_sales) over(partition by order_date order by order_date) as running_total_sales
from moving_avg_cte;

-- part to whole analysis -- 

with category_sales_cte as (
select 
	pp.category as category,
	sum(tt.gross_revenue) as total_sales
from transactions tt
left join products pp
on pp.product_id = tt.product_id
where pp.category is not null
group by pp.category
)

select 
category,
total_sales,
sum(total_sales) over () overall_sales,
concat(ROUND((total_sales / SUM(total_sales) OVER () * 100)::NUMERIC,2), '%') AS percentage_of_sales	
from category_sales_cte
order by total_sales DESC;

-- funnel analysis -- 

create view funnel_analysis as
with funnel_cte as (
select
	event_type as event_type,
	COUNT(event_type) as total_events
from events
group by event_type
order by 
	case 
	when event_type = 'view' then 1
	when event_type = 'click' then 2
	when event_type = 'add_to_cart' then 3
	when event_type = 'purchase' then 4
	else 5
end
)

select
	event_type,
	total_events,
	concat(ROUND((100 * (total_events / sum(total_events) over()))::numeric,2),'%') as percentage_funnel,
	case 
		when lag(total_events) over() - total_events > 0 then (lag(total_events) over() - total_events)
		when lag(total_events) over() - total_events is null then 0
		else sum(total_events) over() - total_events
	end as loss_customers,
	case 
		when 100 *(total_events::float/lag(total_events) over()) < 100 then ROUND((100*(total_events::float/lag(total_events) over()))::NUMERIC,2) 
		when 100 *(total_events::float/lag(total_events) over()) is null then null
		else null
	end as percentage_loss
from funnel_cte;

-- how does the campaigns affect the rest of funnel--

create view campaigns_cte as 
with events_cte as (
select
	ee.event_type as event,
	cc.objective as objective,
	ee.experiment_group as experiment,
	count(ee.customer_id) as customer
from campaigns cc
left join events ee
	on cc.campaign_id = ee.campaign_id
group by event, objective, experiment
order by objective,
		case 
	when event_type = 'view' then 1
	when event_type = 'click' then 2
	when event_type = 'add_to_cart' then 3
	when event_type = 'purchase' then 4
	else 5
end
)

select
	event,
	objective,
	customer,
	experiment,
	sum(customer) over(partition by objective) as total_customer,
	sum(customer) over(partition by objective) - customer as loss_customer,
	concat(ROUND((customer / sum(customer) over(partition by objective)*100)::numeric, 2),'%') as customer_percentage,
	concat(case
		when 100 *(customer::float/lag(customer) over(partition by objective)) < 100 then ROUND((100*(customer::float/lag(customer) over(partition by objective)))::NUMERIC,2)
		when 100 *(customer::float/lag(customer) over()) is null then 0
		else 0
	end
	,'%') as percentage_loss
from events_cte;
	

-- how did the experiment group affect each -- 

with experiment_groups as (
select 
	ee.experiment_group as groups,
	ee.event_type as event_type ,
	count(cc.customer_id) sum_of_customers
from customers cc
left join events ee
	on cc.customer_id = ee.customer_id 
group by ee.experiment_group, ee.event_type
order by groups,
		case 
	when event_type = 'view' then 1
	when event_type = 'click' then 2
	when event_type = 'add_to_cart' then 3
	when event_type = 'purchase' then 4
	else 5
end
)

select
	groups,
	event_type,
	sum_of_customers,
	sum(sum_of_customers) over(partition by groups),
	round((sum_of_customers / sum(sum_of_customers) over(partition by groups)*100.0)::numeric, 2) percentage_per_funnel
from experiment_groups;

-- which campaigns resulted in the most revenue -- 

with campaign_cte as (
	select
		c.target_segment as target,
		c.campaign_id  as campaigns,
		c.channel as channels,
		t.product_id as product,
		t.gross_revenue as gross_revenue,
		t.discount_applied as discount
	from campaigns c
		left join transactions t
			on c.campaign_id = t.campaign_id
),
revenue_cte as 
(
	select 	
		target,
		channels,
		sum(gross_revenue) as revenue
	from campaign_cte cc 
		group by target, channels
		order by target
)
select 
	target,
	channels,
	revenue,
	CONCAT(ROUND((revenue/SUM(revenue) over(partition by target)*100)::numeric,2), '%') as percentage_of_revenue
from revenue_cte;