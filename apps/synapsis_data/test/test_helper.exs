# ADR-006 C4: no PostgreSQL. The embedded Concord store starts with the
# :concord application; ensure it is ready before tests touch Session.Store.
Synapsis.Session.Store.ensure_started()

ExUnit.start()
