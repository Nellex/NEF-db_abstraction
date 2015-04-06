local db = {}

function db:new()
    obj = {}
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function db:set_driver(driver_name)
    driver_name = driver_name or 'pgsql'
    if driver_name == 'pgsql' then
        self.sql = require('lib.db.sql_pgsql')
    end
    --[[if driver_name == 'mysql' then
        self.sql = require('database.sql_mysql')
    end]]
end

function db:connect(host, port, user, password, db_name)
    return self.sql:connect(host, port, user, password, db_name)
end

function db:execute(query)
    return self.sql:execute(query)
end

function db:bind(schema, table)
    self.sql.schema = tostring(schema)
    self.sql.table = tostring(table)
end

function db:get_pk_name()
    return self.sql:get_pk_name()
end

function db:get_pk_fields()
    return self.sql:get_pk_fields()
end

function db:select_all()
    return self.sql:select_all()
end

function db:take(LIMIT)
    return self.sql:take(LIMIT)
end

function db:find(...)
    return self.sql:find(...)
end

function db:first(LIMIT)
    return self.sql:first(LIMIT)
end

function db:last(LIMIT)
    return self.sql:last(LIMIT)
end

function db:create_schema(schema_name)
    return self.sql:create_schema(schema_name)
end

function db:create_table(table, pk_name)
    return self.sql:create_table(table, pk_name)
end

function db:add_column(col_name, col_type, length, default, not_null, pk)
    return self.sql:add_column(col_name, col_type, length, default, not_null, pk)
end

function db:insert(...)
    return self.sql:insert(...)
end

function db:insert_any(...)
    return self.sql:insert_any(...)
end

function db:update(values)
    return self.sql:update(values)
end

function db:delete(...)
    return self.sql:delete(...)
end

function db:where(...)
    return self.sql:where(...)
end

return db
