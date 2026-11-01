CREATE DATABASE IF NOT EXISTS mart;

CREATE TABLE mart.sales_mart
(
    sale_date       Date,
    year            UInt16,
    month           UInt8,
    store_name      String,
    city            String,
    product_name    String,
    category        String,
    quantity        Int32,
    amount          Decimal(12, 2)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(sale_date)
ORDER BY (sale_date, city, category, store_name)
SETTINGS index_granularity = 8192;

INSERT INTO mart.sales_mart
SELECT
    date_key,
    toYear(date_key),
    toMonth(date_key),
    store_name,
    city,
    product_name,
    category,
    quantity,
    amount
FROM postgresql('dwh-postgres:5432', 'dwh', 'sales_denorm', 'postgres', 'postgres', 'core')
WHERE quantity IS NOT NULL AND amount IS NOT NULL;