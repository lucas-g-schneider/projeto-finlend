-- Último autor: estagiário que saiu em janeiro
-- "funciona, não mexe"

SELECT
    transaction_id,
    merchant_id,
    customer_id,
    amount_cents,
    amount_cents / 100 as amount_brl,
    status,
    payment_method,

    created_at,
    updated_at,
    metadata,
    CURRENT_TIMESTAMP() as loaded_at
FROM {{ source('raw', 'transactions') }}
WHERE status != 'test'