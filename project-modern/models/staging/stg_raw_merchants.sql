{{
    config(
        materialized='table'
    )
}}

SELECT
    id AS merchant_id,
    trade_name,
    mcc_code,
    created_at,
    updated_at,
    loaded_at

FROM {{ source('raw', 'merchants') }}
