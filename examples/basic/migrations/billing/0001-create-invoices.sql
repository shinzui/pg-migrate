CREATE TABLE example_invoices (
  id bigint PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES example_accounts (id),
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0)
);
