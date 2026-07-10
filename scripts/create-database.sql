SELECT format('CREATE DATABASE %I', :'database')
WHERE NOT EXISTS
(
    SELECT 1
    FROM pg_database
    WHERE datname = :'database'
)
\gexec
