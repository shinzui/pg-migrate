CREATE TABLE example_accounts (
  id bigint PRIMARY KEY,
  email text NOT NULL UNIQUE
);
