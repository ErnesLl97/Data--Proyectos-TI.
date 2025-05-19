-- Load Geolocation Data
COPY staging.dim_geo (city, state, long, lat)
FROM 'C:\Users\William\Documents\DataScience\blibli\e-commerce-datsci-proj\data\processed\IDN_geo_cleaned.csv' 
DELIMITER ',' 
CSV HEADER;

-- Upsert Date dimension
INSERT INTO staging.dim_date
SELECT TO_CHAR(datum, 'yyyymmdd')::INT AS date_id,
       datum AS date,
       TO_CHAR(datum, 'Day') AS day_name,
       EXTRACT(ISODOW FROM datum) AS day_of_week,
       EXTRACT(DAY FROM datum) AS day_of_month,
       datum - DATE_TRUNC('quarter', datum)::DATE + 1 AS day_of_quarter,
       EXTRACT(DOY FROM datum) AS day_of_year,
       TO_CHAR(datum, 'W')::INT AS week_of_month,
       EXTRACT(WEEK FROM datum) AS week_of_year,
       EXTRACT(MONTH FROM datum) AS month_actual,
       TO_CHAR(datum, 'Month') AS month_name,
       TO_CHAR(datum, 'Mon') AS month_name_abbreviated,
       EXTRACT(QUARTER FROM datum) AS quarter,
       EXTRACT(ISOYEAR FROM datum) AS year,
       CASE
           WHEN EXTRACT(ISODOW FROM datum) IN (6, 7) THEN TRUE
           ELSE FALSE
           END AS isWeekend
FROM (SELECT '2016-01-01'::DATE + SEQUENCE.DAY AS datum
      FROM GENERATE_SERIES(0, 2190) AS SEQUENCE (DAY)
      GROUP BY SEQUENCE.DAY) DQ
ORDER BY 1;

-- Upsert Time dimension
insert into staging.dim_time
select to_char(minute, 'hh24mi')::INT AS time_id,
	-- Hour of the day (0 - 23)
	extract(hour from minute) as hour, 
	-- Extract and format quarter hours
	to_char(minute - (extract(minute from minute)::integer % 15 || 'minutes')::interval, 'hh24:mi') ||
	' – ' ||
	to_char(minute - (extract(minute from minute)::integer % 15 || 'minutes')::interval + '14 minutes'::interval, 'hh24:mi')
		as quarter_hour,
	-- Minute of the day (0 - 1439)
	extract(hour from minute)*60 + extract(minute from minute) as minute,
	-- Names of day periods
	case when to_char(minute, 'hh24:mi') between '00:00' and '06:00'
		then 'Dawn'
	     when to_char(minute, 'hh24:mi') between '06:00' and '11:00'
		then 'Morning'
	     when to_char(minute, 'hh24:mi') between '11:00' and '18:00'
		then 'Afternoon'
	     else 'Evening'
	end as daytime,
	-- Indicator of day or night
	case when to_char(minute, 'hh24:mi') between '07:00' and '19:59' then 'Day'
	     else 'Night'
	end AS daynight
from (SELECT '0:00'::time + (sequence.minute || ' minutes')::interval AS minute
	FROM generate_series(0,1439) AS sequence(minute)
	GROUP BY sequence.minute
     ) DQ
order by 1;

-- Product dimension
-- 3 steps :
-- 1. insert new data
-- 2. insert new change in live database as change in data staging, make it into current version
-- 3. update the second latest version (still in current version flag) into non-current version
insert into staging.dim_product (
	product_id, 
	product_category,
    product_name_length, 
    product_description_length, 
    product_photos_qty, 
    product_weight_g, 
    product_length_cm, 
    product_height_cm, 
    product_width_cm, 
    is_current_version
) 
(select 
	product_id,
    CASE 
         when product_category is not null then product_category
         else 'OTHER'
    END as product_category,
    product_name_length,
    product_description_length,
    product_photos_qty, 
    product_weight_g, 
    product_length_cm, 
    product_height_cm, 
    product_width_cm, 
	true as is_current_version 
	from live.product
	where product_id not in (select product_id from staging.dim_product));

-- User dimension (SCD II)
-- 3 steps :
-- 0. create the aggregate for user data
-- 1. insert new data
-- 2. insert new change in live database as change in data staging, make it into current version
-- 3. update the second latest version (still in current version flag) into non-current version

with deduplicate as (
	select user_name , customer_zip_code , customer_city , customer_state 
	from (
		SELECT 
			DISTINCT *,
			RANK() over(
					PARTITION BY user_name 
					ORDER BY customer_zip_code DESC, customer_state DESC , customer_city DESC
			) as rank
		FROM 
			live.user u
		) dedup 
	where rank = 1
), geolocation as (
	select geo_id, city
	from dim_geo
)
insert into staging.dim_user (
  user_name,
  customer_geo_id,
  is_current_version
)
(
	select
		user_name ,
		geolocation.geo_id,
		true as is_current_version
	from deduplicate d
	left join geolocation on d.customer_city = geolocation.city
	where user_name not in (select user_name from staging.dim_user)
);


-- Seller dimension
-- 3 steps :
-- 1. insert new data
-- 2. insert new change in live database as change in data staging, make it into current version
-- 3. update the second latest version (still in current version flag) into non-current version
with geolocation as (
	select geo_id, city
	from dim_geo
)
insert into staging.dim_seller (
	seller_id ,
	seller_geo_id ,
	is_current_version 
) 
(select 
	s.seller_id,
	geolocation.geo_id,
	true as is_current_version
	from live.seller s
	left join geolocation on s.seller_city = geolocation.city
	where seller_id not in (select seller_id from staging.dim_seller)
);

-- Feedback dimension
with deduplicate_order as (
	select feedback_id, feedback_score, feedback_form_sent_date, feedback_answer_date 
	from (
		select
		distinct *,
			rank() over (
				partition by order_id 
				ORDER BY feedback_answer_date desc, feedback_form_sent_date DESC
			) as rank
		from 
			live.feedback f
		order by rank desc
	) dedup 
	where dedup.rank = 1
), deduplicate_feedback as (
	select
		 distinct *,
			rank() over (
				partition by feedback_id 
				ORDER BY feedback_answer_date desc, feedback_form_sent_date DESC
			) as rank
		from 
			deduplicate_order
		order by rank desc
)
insert into staging.dim_feedback (
  feedback_id,
  feedback_score,
  feedback_form_sent_date,
  feedback_form_sent_time,
  feedback_answer_date,
  feedback_answer_time,
  is_current_version
)
(
	select 
		d.feedback_id,
		d.feedback_score ,
		TO_CHAR(d.feedback_form_sent_date , 'yyyymmdd')::INT as feedback_form_sent_date,
		TO_CHAR(d.feedback_form_sent_date , 'hh24mi')::INT as feedback_form_sent_time,
		TO_CHAR(d.feedback_answer_date , 'yyyymmdd')::INT as feedback_answer_date,
		TO_CHAR(d.feedback_answer_date , 'hh24mi')::INT as feedback_answer_time,
		true as is_current_version
	from deduplicate_feedback d
);
