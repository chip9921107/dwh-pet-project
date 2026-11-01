-- ============================================
-- Слой Staging (сырые данные)
-- ============================================

CREATE SCHEMA IF NOT EXISTS staging;

-- Сырые продажи
CREATE TABLE staging.stg_sales (
    sale_id         BIGINT,
    sale_date       TEXT,           -- дата как строка, как пришла из источника
    store_id        TEXT,
    product_id      TEXT,
    quantity        TEXT,           -- количество как строка (в источнике может быть "2", "2.0", " 2 ")
    amount          TEXT,           -- сумма как строка
    load_ts         TIMESTAMP DEFAULT now()
);

-- Сырой справочник товаров
CREATE TABLE staging.stg_products (
    product_id      TEXT,
    product_name    TEXT,
    category        TEXT,
    price           TEXT,
    valid_from      TEXT,           -- для последующей обработки SCD Type 2
    load_ts         TIMESTAMP DEFAULT now()
);

-- Сырой справочник магазинов
CREATE TABLE staging.stg_stores (
    store_id        TEXT,
    store_name      TEXT,
    city            TEXT,
    load_ts         TIMESTAMP DEFAULT now()
);

-- Индексы для ускорения последующей обработки
CREATE INDEX idx_stg_sales_date ON staging.stg_sales (sale_date);
CREATE INDEX idx_stg_sales_product ON staging.stg_sales (product_id);
CREATE INDEX idx_stg_products_id ON staging.stg_products (product_id);
CREATE INDEX idx_stg_stores_id ON staging.stg_stores (store_id);

-- Комментарии к таблицам и полям (это уже часть техдокументации)
COMMENT ON SCHEMA staging IS 'Слой сырых данных, максимально близких к источнику';
COMMENT ON TABLE staging.stg_sales IS 'Сырые продажи из кассовой системы';
COMMENT ON COLUMN staging.stg_sales.sale_date IS 'Дата продажи в формате источника (TEXT)';
COMMENT ON COLUMN staging.stg_sales.quantity IS 'Количество, хранится как TEXT для сохранения исходного формата';
COMMENT ON TABLE staging.stg_products IS 'Сырой справочник товаров';
COMMENT ON TABLE staging.stg_stores IS 'Сырой справочник магазинов';