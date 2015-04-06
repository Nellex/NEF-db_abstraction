local sql = {}
sql.adapter = require('pgsql')
sql.fs = require('lfs')
sql.json = require('cjson')
sql.cache = {}
sql.cache_state = 0
sql.types = {
    ['bigint'] = 0,
    ['bigserial'] = 0,
    ['bit'] = 1,
    ['bit varying'] = 1,
    ['boolean'] = 0,
    ['bytea'] = 0,
    ['char'] = 1,
    ['character'] = 1,
    ['character varying'] = 1,
    ['date'] = 0,
    ['daterange'] = 0,
    ['inet'] = 0,
    ['integer'] = 0,
    ['json'] = 0,
    ['macaddr'] = 0,
    ['numeric'] = 1,
    ['numrange'] = 0,
    ['real'] = 0,
    ['serial'] = 0,
    ['smallint'] = 0,
    ['smallserial'] = 0,
    ['text'] = 0,
    ['time without time zone'] = 0,
    ['timewotz'] = 0,
    ['timestamp without time zone'] = 0,
    ['timestampwotz'] = 0,
    ['varbit'] = 1,
    ['varchar'] = 1,
    ['xml'] = 0
}

sql.types_to_convert = {
    ['bigserial'] = 'bigint',
    ['char'] = 'character',
    ['serial'] = 'integer',
    ['timewotz'] = 'time without time zone',
    ['timestampwotz'] = 'timestamp without time zone',
    ['varbit'] = 'bit varying',
    ['varchar'] = 'character varying'
}

sql.where_operators = {
    ['build'] = '',
    ['and'] = ' AND ',
    ['or'] = ' OR ',
    ['AND'] = ' AND ',
    ['OR'] = ' OR ',
    ['arithmetic'] = {['='] = ' = ', ['!='] = ' != ',
                      ['>'] = ' > ', ['<'] = ' < ',
                      ['>='] = ' >= ', ['<='] = ' <= '},
    ['in'] = ' IN ',
    ['not in'] = ' NOT IN ',
    ['between'] = ' BETWEEN ',
    ['not between'] = ' NOT BETWEEN ',
    ['like'] = ' LIKE ',
    ['not like'] = ' NOT LIKE '
}

sql.errors = {
    [1] = 'db:bind() not initialized!',
    [2] = 'parameter must be table!',
    [3] = 'number of arguments does not match the number of fields',
    [4] = 'db:where() not initialized!',
    [5] = 'db:where(): operator must be a string!',
    [6] = 'db:where(): operator is emty!'
}

function sql:split(str, sep)
    str = str or '%s'
    local t={} ; i=1
    for split_str in string.gmatch(str, "([^"..sep.."]+)") do
        t[i] = split_str
        i = i + 1
    end
    return t
end

function sql:type_convert(col_type)
    local col_type = tostring(col_type)
    if self.types_to_convert[col_type] then return self.types_to_convert[col_type] end
    return col_type
end

function sql:table_len(table)
    if (type(table) == 'table') then
        local len = 0
        for k in pairs(table) do len = len + 1 end
        return len
    end
    return false
end

function sql:cache_read()
    --not use assert for next call cache_update
    local file = io.open(self.fs.currentdir() .. '/' .. self.db_name .. '_db.cache', 'r')
    if not file then return 0 end
    self.cache = file:read('*a')
    file:close()
    self.cache = self.json.decode(self.cache)
    return 1
end

function sql:cache_update()
    if not self.schema then return self.errors[1] end
    local cache = {}
    cache[self.schema] = {}
    self:execute('SELECT table_name, table_type FROM information_schema.tables WHERE table_schema=\''
                .. self.schema .. '\'')
    local tables = self:to_obj()
    self:execute('SELECT table_constraints.constraint_schema, table_constraints.table_name,'
    .. ' constraint_column_usage.column_name, table_constraints.constraint_name, table_constraints.constraint_type'
    .. ' FROM information_schema.constraint_column_usage JOIN information_schema.table_constraints'
    .. ' ON constraint_column_usage.constraint_name = table_constraints.constraint_name')
    local constraints = self:to_obj()
    self:execute('SELECT idx.indrelid :: REGCLASS AS table_name, i.relname AS index_name, am.amname AS type,'
    .. ' ARRAY(SELECT pg_get_indexdef(idx.indexrelid, k + 1, TRUE) FROM generate_subscripts(idx.indkey, 1) AS k'
    .. ' ORDER BY k) AS columns FROM pg_index AS idx JOIN pg_class AS i ON i.oid = idx.indexrelid JOIN pg_am'
    .. ' AS am ON i.relam = am.oid JOIN pg_namespace AS NS ON i.relnamespace = NS.OID WHERE nspname=\''
    .. self.schema .. '\' AND i.relname NOT IN (SELECT constraint_name FROM information_schema.table_constraints)')
    local indexes = self:to_obj()
    local schema_name = ''
    local table_name = ''
    local columns = {}
    for i=1, #tables, 1 do
        table_name = tables[i]['table_name']
        cache[self.schema][table_name] = {['table_type'] =  tables[i]['table_type'], ['columns'] = {},
        ['constraints'] = {}}
        self:execute('SELECT column_name AS name, ordinal_position AS position, column_default AS default,'
        .. ' Is_nullable AS not_null, data_type AS type, character_maximum_length AS length FROM'
        .. ' information_schema.columns WHERE table_schema=\'' .. self.schema .. '\' AND'
        .. ' table_name=\'' .. table_name .. '\'')
        columns = self:to_obj()
        for j=1, #columns, 1 do
            --check default value for matching Sequence Manipulation Functions
            local is_currval = string.match(columns[j]['default'], 'currval')
            local is_lastval = string.match(columns[j]['default'], 'lastval')
            local is_nextval = string.match(columns[j]['default'], 'nextval')
            local is_setval = string.match(columns[j]['default'], 'setval')
            local is_func = false
            if (is_currval or is_lastval or is_nextval or is_setval) then is_func = true end
            --adaption to serial, bigserial
            if (is_nextval and columns[j]['type'] == 'integer') then
                columns[j]['type'] = 'serial'
                columns[j]['default'] = ''
            end
            if (is_nextval and columns[j]['type'] == 'bigint') then
                columns[j]['type'] = 'bigserial'
                columns[j]['default'] = ''
            end
            --cut default value notation
            if not is_func then
                local str_replace = '::' .. columns[j]['type']
                columns[j]['default'] = string.gsub(columns[j]['default'], str_replace, '')
            end
            --move "YES" or "NO" to 1 or 0
            if (columns[j]['not_null'] == 'YES') then
                columns[j]['not_null'] = 0
            elseif (columns[j]['not_null'] == 'NO') then
                columns[j]['not_null'] = 1
            end
            --end of preparations;)
            cache[self.schema][table_name]['columns'][j] = {
                columns[j]['name'],
                columns[j]['type'],
                columns[j]['length'],
                columns[j]['default'],
                columns[j]['not_null'],
                columns[j]['position']
            }
        end
    end
    for i=1, #constraints, 1 do
        if (constraints[i]['constraint_schema'] == self.schema and cache[self.schema][constraints[i]['table_name']]) then
            table_name = constraints[i]['table_name']
            if (not cache[self.schema][table_name]['constraints'][constraints[i]['constraint_name']]) then
                cache[self.schema][table_name]['constraints'][constraints[i]['constraint_name']] = {
                    ['type'] = constraints[i]['constraint_type'],
                    ['columns'] = {}
                }
                table.insert(cache[self.schema][table_name]['constraints'][constraints[i]['constraint_name']]['columns'],
                constraints[i]['column_name'])
            else
                table.insert(cache[self.schema][table_name]['constraints'][constraints[i]['constraint_name']]['columns'],
                constraints[i]['column_name'])
            end
        end
    end
    for k, index in pairs(indexes) do
        table_name = self:split(index['table_name'], '.'); schema_name = table_name[1]; table_name = table_name[2]
        if (schema_name == self.schema and self.cache[self.schema][table_name]) then
            index['columns'] = string.gsub(index['columns'], '{', '')
            index['columns'] = string.gsub(index['columns'], '}', '')
            index['columns'] = self:split(index['columns'], ',')
            if (not cache[self.schema][table_name]['indexes']) then cache[self.schema][table_name]['indexes'] = {} end
            cache[self.schema][table_name]['indexes'][index['index_name']] = {
                ['type'] = index['type'],
                ['columns'] = {}
            }
            table.insert(cache[self.schema][table_name]['indexes'][index['index_name']]['columns'], index['columns'])
        end
    end
    self.cache[self.schema] = cache[self.schema]
    cache = nil
    local file = assert(io.open(self.fs.currentdir() .. '/' .. self.db_name .. '_db.cache', 'w'))
    assert(file:write(self.json.encode(self.cache)))
    file:close()
    self.cache_state = 1
end

function sql:is_column(field)
    if (self.schema and self.table) then
        local columns = self.cache[self.schema][self.table]['columns']
        for i=1, #columns, 1 do
            if (columns[i][1] == tostring(field)) then return true end
        end
    end
    return false
end

function sql:is_constraint(field)
    if (self.schema and self.table) then
        local field = tostring(field)
        if (self.cache[self.schema][self.table]['constraints'][field]) then return true end
    end
    return false
end

function sql:is_index(field)
    if (self.schema and self.table) then
        local field = tostring(field)
        if self.cache[self.schema][self.table]['indexes'][field] then return true end
    end
    return false
end

--reset old connection in object:
--object.sql.sconnection = false
--object:connect(host, port, user, password, db_name)
function sql:connect(host, port, user, password, db_name)
    if not self.sconnection then
        self.host = tostring(host)
        self.port = tostring(port)
        self.user = tostring(user)
        self.password = tostring(password)
        self.db_name = tostring(db_name)
        self.conninfo = 'host=' .. self.host .. ' port='.. self.port .. ' user=' .. self.user
        .. ' password=' .. self.password .. ' dbname=' .. self.db_name
    end
    self.connection = self.adapter.connectdb(self.conninfo)
    if self.connection:status()  == self.adapter.CONNECTION_OK then
        self.sconnection = true
        self.cache_state = self:cache_read()
        return true
    end
    return false, self.connection:errorMessage()
end

function sql:execute(query)
    local query = tostring(query)
    self.res = self.connection:exec(query)
    return self.res:resStatus(self.res:status())
end

function sql:to_obj()
    local r, c = self.res:ntuples(), self.res:nfields()
    local c_names, obj = {}, {}
    for i=1, c, 1 do
        c_names[i] = self.res:fname(tostring(i))
    end
    for i=1, r, 1 do
        obj[i] = {}
        for j=1, c, 1 do
            obj[i][c_names[j]] = self.res:getvalue(i, j)
        end
    end
    return obj, c_names
end

function sql:get_pk_name()
    if (self.schema and self.table) then
        self:execute('SELECT constraint_name FROM information_schema.table_constraints WHERE constraint_schema=\''
        .. self.schema .. '\' AND table_name=\''.. self.table ..'\' AND constraint_type=\'PRIMARY KEY\' LIMIT 1')
        local pk = self:to_obj()
        self.pk_name = pk[1]['constraint_name']
        return true
    end
    return self.errors[1]
end

function sql:get_pk_fields()
    if (self.schema and self.table) then
        self:get_pk_name()
        self:execute('SELECT column_name FROM information_schema.constraint_column_usage WHERE constraint_schema=\''
        .. self.schema .. '\' AND table_name=\''.. self.table .. '\' AND constraint_name=\'' .. self.pk_name .. '\'')
        local obj = {}
        for i=1, self.res:ntuples(), 1 do
            obj[i] = self.res:getvalue(i, 1)
        end
        return obj
    end
    return self.errors[1]
end

function sql:create_schema(schema_name)
    local schema_name = tostring(schema_name)
    local query = 'BEGIN;\nCREATE SCHEMA ' .. schema_name .. ' AUTHORIZATION ' .. self.user
    .. ';\nGRANT ALL ON SCHEMA ' .. schema_name .. ' TO ' .. self.user .. ';\nCOMMIT;'
    return self:execute(query)
end

function sql:create_table(table_def, pk_name)
    if (type(table_def) ~= 'table') then return self.errors[2] end
    if not self.schema then return self.errors[1] end
    local query = 'CREATE TABLE ' .. self.schema .. '.' .. self.table .. '\n(\n'
    local pk_str = 'CONSTRAINT ' .. tostring(pk_name) .. ' PRIMARY KEY ('
    local pk_sep = ''--separator
    for idx, field in pairs(table_def) do
        if self.types[field[2]] then
            --{'field_name', 'type', 'len' or 0, 'default value' or 0, 'not null - 1' or 0, 'PK'}
            field[2] = self:type_convert(field[2])
            query = query .. tostring(field[1]) .. ' ' .. tostring(field[2])
            if (field[3] and field[3] ~= 0) then query = query .. '(' .. tostring(field[3]) .. ')' end
            if (field[4] and field[4] ~= 0) then
                query = query .. ' DEFAULT ' .. '\'' .. tostring(field[4]) .. '\'::' .. tostring(field[2])
            end
            if (field[5] and field[5] ~= 0) then query = query .. ' NOT NULL' end
            if (field[6] and field[6] == 'PK') then
                pk_str = pk_str .. pk_sep .. tostring(field[1])
                if pk_sep == '' then pk_sep = ', ' end
            end
            if idx == #table_def then
                query = query .. ',\n' .. pk_str .. ')\n)\nWITH (\nOIDS=FALSE\n);\nALTER TABLE '
                .. self.schema .. '.' .. self.table .. '\nOWNER TO ' .. self.user ..';'
            else
                query = query .. ',\n'
            end
        else
            return 'db:create_table: unknown type: ' .. tostring(field[2])
        end
    end
    local res = self:execute(query)
    self:cache_update()
    return res
end

function sql:add_column(col_name, col_type, length, default, not_null, pk)
    if (self.schema and self.table) then
        if self:is_column(col_name) then return 'db:add_column: this column already exist!' end
        if not self.types[col_type] then return 'db:add_column: unknown type: ' .. tostring(col_type) end
        col_type = self:type_convert(col_type)
        local transaction = 'BEGIN;\nALTER TABLE ' .. self.schema .. '.' .. self.table .. ' ADD COLUMN "'
        .. col_name .. '" ' .. col_type
        if (type(length) == 'number' and self.types[col_type] == 1) then
            transaction = transaction .. '(' .. tostring(length) .. ')'
        end
        transaction = transaction .. ';\n'
        if (default and type(default) ~= 'table') then
            transaction = transaction .. 'ALTER TABLE ' .. self.schema .. '.' .. self.table .. ' ALTER COLUMN "'
            .. col_name .. '" SET DEFAULT \'' .. tostring(default) .. '\';\n'
        end
        if (not_null == 1) then
            transaction = transaction .. 'ALTER TABLE ' .. self.schema .. '.' .. self.table .. ' ALTER COLUMN "'
            .. col_name .. '" SET NOT NULL;\n'
        end
        if (pk and self:get_pk_name()) then
            local pk_fields = self:get_pk_fields()
            transaction = transaction .. 'ALTER TABLE ' .. self.schema .. '.' .. self.table .. ' DROP CONSTRAINT '
            .. self.pk_name .. ';\nALTER TABLE ' .. self.schema .. '.' .. self.table .. ' ADD CONSTRAINT '
            .. self.pk_name .. ' PRIMARY KEY('
            for k, v in pairs(pk_fields) do transaction = transaction .. v .. ',' end
            transaction = transaction .. col_name .. ');\n'
        end
        transaction = transaction .. 'COMMIT;'
        local res = self:execute(transaction)
        self:cache_update()
        return res
    end
    return self.errors[1]
end

function sql:add_unique(unique_name, columns)
    if (self.schema and self.table) then
        if (type(unique_name) ~= 'string') then return 'db:add_unique: unique_name must be a string!' end
        if (type(columns) ~= 'table') then return 'db:add_unique: columns must be a table!' end
        if (not self:is_constraint(unique_name)) then
            local query = 'ALTER TABLE ' .. self.schema .. '.' .. self.table ..' ADD CONSTRAINT "' .. unique_name
            .. '" UNIQUE('
            local columns_len = self:table_len(columns)
            local i = 0
            for k, column in pairs(columns) do
                i = i + 1
                if (self:is_column(column)) then
                    query = query .. column
                    if (i < columns_len) then query = query .. ', ' end
                end
            end
            query = query .. ')'
            local res = self:execute(query)
            self:cache_update()
            return res
        end
        return 'db:add_unique: unique_name is already exist!'
    end
    return self.errors[1]
end

function sql:add_pk(pk_name, columns)
    if (self.schema and self.table) then
        if (type(pk_name) ~= 'string') then return 'db:add_pk: pk_name must be a string!' end
        if (type(columns) ~= 'table') then return 'db:add_pk: columns must be a table!' end
        if (not self:is_constraint(pk_name)) then
            local query = 'ALTER TABLE ' .. self.schema .. '.' .. self.table ..' ADD CONSTRAINT "' .. pk_name
            .. '" PRIMARY KEY('
            local columns_len = self:table_len(columns)
            local i = 0
            for k, column in pairs(columns) do
                i = i + 1
                if (self:is_column(column)) then
                    query = query .. column
                    if (i < columns_len) then query = query .. ', ' end
                end
            end
            query = query .. ')'
            local res = self:execute(query)
            self:cache_update()
            return res
        end
        return 'db:add_pk: pk_name is already exist!'
    end
    return self.errors[1]
end

--fk_def = {
--['columns'] = {'name', 'lastname'},
--['table'] = 'schema_name.table_name',
--['table_columns'] = {'person_name', 'person_lastname'},
--['match_mode'] = 1 or 2 or 3, --eq 'full' or 'partial' or 'simple'
--['on_update'] = 1 or 2 or 3 or 4 or 5, --eq 'no action' or 'restrict' or 'cascade' or 'set null' or 'set default'
--['on_delete'] = 1 or 2 or 3 or 4 or 5, --eq 'no action' or 'restrict' or 'cascade' or 'set null' or 'set default'
--['deferrable'] = true or false,
--['deferred'] = true or false
--}
function sql:add_fk(fk_name, fk_def)
    if (self.schema and self.table) then
        if (type(fk_name) ~= 'string') then return 'db:add_fk: fk_name must be a string!' end
        if (type(fk_def) ~= 'table') then return 'db:add_fk: fk_def must be a table!' end
        if (self:is_constraint(pk_name)) then return 'db:add_fk: fk_name is already exist!' end
        local fk_def_schema = {
            ['columns'] = 'table',
            ['table'] = 'string',
            ['table_columns'] = 'table',
            ['match_mode'] = 'number',
            ['on_update'] = 'number',
            ['on_delete'] = 'number',
            ['deferrable'] = 'number',
            ['deferred'] = 'number'
        }
        local query = 'ALTER TABLE ' .. self.schema .. '.' .. self.table ..' ADD CONSTRAINT "' .. fk_name
        .. '" FOREIGN KEY (Pcolumns1) REFERENCES Ptable (Pcolumns2) MATCH Pmatch_mode ON UPDATE Pon_update'
        .. ' ON DELETE Pon_delete Pdeferrable Pdeferred'
        local fk_def_complete_state = 0
        local query_complete_state = 0
        for k, v in pairs(fk_def_schema) do
            if (fk_def[k]) then
                if (type(fk_def[k]) == v) then
                    fk_def_complete_state = fk_def_complete_state + 1
                else
                    return 'db:add_fk: ' .. k .. ' must be a ' .. v .. '!'
                end
            else
                return 'db:add_fk: ' .. k .. ' field is not defined!'
            end
        end
        local columns_ratio = self:table_len(fk_def['columns']) % self:table_len(fk_def['table_columns'])
        if (fk_def_complete_state == 8 and columns_ratio == 0) then
            local tmp_str = ''
            local columns_len = self:table_len(fk_def['columns'])
            local i = 0
            for k, column in pairs(fk_def['columns']) do
                i = i + 1
                if (not self:is_column(column)) then
                    return 'db:add_fk: column "' .. column .. '" not found, use sql.cache_update()'
                end
                tmp_str = tmp_str .. '"' .. column .. '"'
                if (i < columns_len) then tmp_str = tmp_str .. ', ' end
            end
            query = string.gsub(query, 'Pcolumns1', tmp_str)
            tmp_str = ''
            query_complete_state = query_complete_state + 1
            fk_def['table'] = self:split(fk_def['table'], '.')
            if (not self.cache[fk_def['table'][1]][fk_def['table'][2]]) then
                return 'db:add_fk: table "' .. fk_def['table'][1] .. '.' .. fk_def['table'][2]
                .. '" not found, use sql.cache_update()'
            end
            query = string.gsub(query, 'Ptable', fk_def['table'][1] .. '.' .. fk_def['table'][2])
            query_complete_state = query_complete_state + 1
            local old_schema, old_table = self.schema, self.table
            self.schema, self.table = fk_def['table'][1], fk_def['table'][2]
            columns_len = self:table_len(fk_def['table_columns'])
            local i = 0
            for k, column in pairs(fk_def['table_columns']) do
                i = i + 1
                if (not self:is_column(column)) then
                    return 'db:add_fk: column "' .. column .. '" not found, use sql.cache_update()'
                end
                tmp_str = tmp_str .. '"' .. column .. '"'
                if (i < columns_len) then tmp_str = tmp_str .. ', ' end
            end
            self.schema, self.table = old_schema, old_table
            query = string.gsub(query, 'Pcolumns2', tmp_str)
            query_complete_state = query_complete_state + 1
            local matches = {
                [1] = 'FULL',
                [2] = 'PARTIAL',
                [3] = 'SIMPLE'
            }
            if (fk_def['match_mode'] > 0 and fk_def['match_mode'] < 4) then
                query = string.gsub(query, 'Pmatch_mode', matches[fk_def['match_mode']])
                query_complete_state = query_complete_state + 1
            else
                return 'db:add_fk: unknown match_mode!'
            end
            local on_action = {
                [1] = 'NO ACTION',
                [2] = 'RESTRICT',
                [3] = 'CASCADE',
                [4] = 'SET NULL',
                [5] = 'SET DEFAULT'
            }
            if (fk_def['on_update'] > 0 and fk_def['on_update'] < 6) then
                query = string.gsub(query, 'Pon_update', on_action[fk_def['on_update']])
                query_complete_state = query_complete_state + 1
            else
                return 'db:add_fk: on_update - unknown parameter!'
            end
            if (fk_def['on_delete'] > 0 and fk_def['on_delete'] < 6) then
                query = string.gsub(query, 'Pon_delete', on_action[fk_def['on_delete']])
                query_complete_state = query_complete_state + 1
            else
                return 'db:add_fk: on_delete - unknown parameter!'
            end
            if (fk_def['deferrable'] == 1) then
                query = string.gsub(query, 'Pdeferrable', 'DEFERRABLE')
                query_complete_state = query_complete_state + 1
            else
                query = string.gsub(query, 'Pdeferrable', 'NOT DEFERRABLE')
                query_complete_state = query_complete_state + 1
            end
            if (fk_def['deferred'] == 1) then
                query = string.gsub(query, 'Pdeferred', 'INITIALLY DEFERRED')
                query_complete_state = query_complete_state + 1
            else
                query = string.gsub(query, 'Pdeferred', 'INITIALLY IMMEDIATE')
                query_complete_state = query_complete_state + 1
            end
        end
        if (query_complete_state == 8) then
            local res = self:execute(query)
            self:cache_update()
            return res
        else
            return 'db:add_fk: not all arguments defined!'
        end
    end
    return self.errors[1]
end

function sql:create_index(index_name, columns)
    if (self.schema and self.table) then
        
    end
    return self.errors[1]
end

function sql:drop_schema(schema)
    if (type(schema) ~= 'table') then
        local res = self:execute('DROP SCHEMA ' .. tostring(schema))
        self:cache_update()
        return res
    end
end

function sql:truncate(restart, cascade)
    if (self.schema and self.table) then
        if restart then
            return self:execute('TRUNCATE ' .. self.schema .. '.' .. self.table .. ' RESTART IDENTITY')
        end
        if cascade then return self:execute('TRUNCATE ' .. self.schema .. '.' .. self.table .. ' CASCADE') end
        return self:execute('TRUNCATE ' .. self.schema .. '.' .. self.table)
    end
    return self.errors[1]
end

function sql:drop_table(table)
    if (self.schema and type(table) ~= 'table') then
        local res = self:execute('DROP TABLE ' .. self.schema .. '.' .. tostring(table))
        self:cache_update()
        return res
    end
    return self.errors[1]
end

function sql:drop_column(column)
    if (self.schema and self.table and type(column) ~= 'table') then
        local res = self:execute('ALTER TABLE ' .. self.schema .. '.' .. self.table .. ' DROP COLUMN '
        .. tostring(column))
        self:cache_update()
        return res
    end
    return self.errors[1]
end

function sql:select_all()
    if (self.schema and self.table) then
        self:execute('SELECT * FROM ' .. self.schema .. '.' .. self.table)
        return self:to_obj()
    end
    return self.errors[1]
end

function sql:take(LIMIT)
    if (self.schema and self.table) then
        self:execute('SELECT * FROM ' .. self.schema .. '.' .. self.table .. ' LIMIT ' .. tostring(LIMIT))
        return self:to_obj()
    end
    return self.errors[1]
end

function sql:find(...)
    local args = {...}
    local pk_fields = self:get_pk_fields()
    if (type(pk_fields) == 'table') then
        local query = ' WHERE '
        for i=1, #pk_fields, 1 do
            query = query .. pk_fields[i] .. '=\'' .. tostring(args[i]) .. '\''
            if (i < #pk_fields) then query = query .. ' AND ' end
        end
        query = 'SELECT * FROM ' .. self.schema .. '.' .. self.table .. query--.. ' LIMIT 1'
        self:execute(query)
        return self:to_obj()
    end
    return pk_fields
end

function sql:first(LIMIT)
    local pk_fields = self:get_pk_fields()
    if (type(pk_fields) == 'table') then
        LIMIT = tostring(LIMIT)
        local query = 'SELECT * FROM ' .. self.schema .. '.' .. self.table .. ' ORDER BY '
        for i=1, #pk_fields, 1 do
            if (i == #pk_fields) then
                query = query .. pk_fields[i] .. ' ASC LIMIT ' .. LIMIT
                break
            end
            query = query .. pk_fields[i] .. ', '
        end
        self:execute(query)
        return self:to_obj()
    end
    return pk_fields
end

function sql:last(LIMIT)
    local pk_fields = self:get_pk_fields()
    if (type(pk_fields) == 'table') then
        LIMIT = tostring(LIMIT)
        local query = 'SELECT * FROM ' .. self.schema .. '.' .. self.table .. ' ORDER BY '
        for i=1, #pk_fields, 1 do
            if (i == #pk_fields) then
                query = query .. pk_fields[i] .. ' DESC LIMIT ' .. LIMIT
                break
            end
            query = query .. pk_fields[i] .. ', '
        end
        self:execute(query)
        return self:to_obj()
    end
    return pk_fields
end

function sql:insert(...)
    local args = {...}
    if (self.schema and self.table) then
        local columns = self.cache[self.schema][self.table]['columns']
        local columns_ratio = #args % #columns
        if (columns_ratio > 0) then return self.errors[3] end
        local query = 'INSERT INTO ' .. self.schema .. '.' .. self.table .. ' ('
        local values = ' VALUES ('
        for i=1, #columns, 1 do
            if (#tostring(args[i]) > 0) then
                if (i == #columns) then
                    query = query .. columns[i][1] .. ')' .. values .. '\'' .. tostring(args[i]) .. '\'' .. ')'
                    values = nil
                    break
                end
                query = query .. columns[i][1] .. ', '
                values = values .. '\'' .. tostring(args[i]) .. '\'' .. ', '
            end
        end
        return self:execute(query)
    end
    return self.errors[1]
end

function sql:insert_any(...)
    local args = {...}
    if (self.schema and self.table) then
        local columns = self.cache[self.schema][self.table]['columns']
        local columns_ratio = #args % #columns
        if (columns_ratio > 0) then return self.errors[3] end
        local transaction = 'BEGIN;\n'
        local query, values = '', ''
        local start_pos, finish_pos = 1, #columns
        local args_full, j = false , 0
        repeat
            query = 'INSERT INTO ' .. self.schema .. '.' .. self.table .. ' ('
            values = ' VALUES ('
            j = 1
            for i=start_pos, finish_pos, 1 do
                if (#tostring(args[i]) > 0) then
                    if (i == finish_pos) then
                        query = query .. columns[j][1] .. ')' .. values .. '\'' .. tostring(args[i]) .. '\'' .. ')'
                        values = nil
                        break
                    end
                    query = query .. columns[j][1] .. ', '
                    values = values .. '\'' .. tostring(args[i]) .. '\'' .. ', '
                end
                j = j + 1
            end
            transaction = transaction .. query .. ';\n'
            if finish_pos == #args then args_full = true end
            start_pos = finish_pos + 1
            finish_pos = finish_pos + #columns
        until args_full
        transaction = transaction .. 'COMMIT;'
        return self:execute(transaction)
    end
    return self.errors[1]
end

function sql:update(values)
    if (type(values) ~= 'table') then return self.errors[2] end
    if not self.cwhere then return self.errors[4] end
    if (self.schema and self.table) then
        local columns = self.cache[self.schema][self.table]['columns']
        local query = 'UPDATE ' .. self.schema .. '.' .. self.table .. ' SET '
        local i, values_len = 0, self:table_len(values)
        for k, v in pairs(values) do
            i = i + 1
            if (self:is_column(k) and type(v) ~= 'table') then
                query = query .. k .. '=\'' .. tostring(v) .. '\''
                if (i < values_len) then query = query .. ', ' end
            end
        end
        query = query .. self:where 'build'
        self.cwhere = nil
        return self:execute(query)
    end
    return self.errors[1]
end

function sql:delete(...)
    local args = {...}
    if (self.schema and self.table) then
        local query = 'DELETE FROM ' .. self.schema .. '.' .. self.table
        if self.cwhere then
            query = query .. self:where 'build'
            self.cwhere = nil
            return self:execute(query)
        end
        if not self.cwhere then
            local pk_fields = self:get_pk_fields()
            if (#args > 0 and type(pk_fields) == 'table') then
                query = ' WHERE '
                for i=1, #pk_fields, 1 do
                    query = query .. pk_fields[i] .. '=\'' .. tostring(args[i]) .. '\''
                    if (i < #pk_fields) then query = query .. ' AND ' end
                end
                query = 'DELETE FROM ' .. self.schema .. '.' .. self.table .. query
            else
                return 'db:delete(): no arguments, use db:where() or list arguments in function!'
            end
            return self:execute(query)
        end
    end
    return self.errors[1]
end
--constructor sub
function sql:where(...)
    if (not self.schema or not self.table) then return self.errors[1] end
    local args = {...}
    local operator, op1, op2, op3 = args[1], args[2], args[3], args[4]
    args = nil
    if (type(operator) ~= 'string') then return self.errors[5] end
    if (operator == '') then return self.errors[6] end
    if not self.cwhere then self.cwhere = {} end
    local columns = self.cache[self.schema][self.table]['columns']
    if (operator == 'and' or operator == 'or') then
        if (#self.cwhere > 0) then
            op2, op3 = nil
            if (type(op1) == 'table') then
                local p_operator, field, cond = '', '', ''
                for k, v in pairs(op1) do
                    if (type(k) == 'number' and k == 1) then p_operator = v end
                    if (type(k) == 'string' and type(v) ~= 'table') then field, cond = k, v end
                end
                if self:is_column(field) then
                    local cond_pos = self:where(p_operator, field, cond)
                    local tmp_str = ''
                    for i=1, #self.cwhere, 1 do
                        if (i == cond_pos) then
                            tmp_str = tmp_str .. self.where_operators[operator] .. self.cwhere[i]
                            break
                        end
                        tmp_str = tmp_str .. self.cwhere[i]
                    end
                    self.cwhere = {}
                    self.cwhere[1] = tmp_str
                    tmp_str = nil
                    return 1
                end
                return 'db:where(): column "%field%" not found, use sql.cache_update()'
            else
                return 'db:where(): operand1 must be a table!'
            end
        else
            return 'db:where(): operator "and" or "or" can\'t be used in first expression!'
        end
    end
    if (operator == 'build' and #self.cwhere > 0) then return ' WHERE ' .. self.cwhere[#self.cwhere] end
    if (operator == 'AND' or operator == 'OR') then
        if (#self.cwhere > 1) then
            local tmp_str = ''
            for i=1, #self.cwhere, 1 do
                tmp_str = tmp_str .. '(' .. self.cwhere[i] .. ')'
                if (i < #self.cwhere) then
                    tmp_str = tmp_str .. self.where_operators[operator]
                end
            end
            self.cwhere = {}
            self.cwhere[1] = tmp_str
            tmp_str = nil
            return 1
        end
        return 'db:where(): not all of the conditions listed!'
    end
    if (type(op1) == 'string') then
        if not self:is_column(op1) then return 'db:where(): column "%field%" not found, use sql.cache_update()' end
        if (self.where_operators.arithmetic[operator] and type(op2) ~= 'table') then
            self.cwhere[#self.cwhere+1] = op1 .. self.where_operators.arithmetic[operator] .. '\'' .. tostring(op2) .. '\''
            return #self.cwhere
        end
        if ((operator == 'in' or operator == 'not in') and type(op2) == 'table') then
            local tmp_str = ''
            local i, op2_len = 0, self:table_len(op2)
            for k, v in pairs(op2) do
                i = i + 1
                tmp_str = tmp_str .. '\'' .. tostring(v) .. '\''
                if (i < op2_len) then tmp_str = tmp_str .. ', ' end
            end
            self.cwhere[#self.cwhere+1] = op1 .. self.where_operators[operator] .. '(' .. tmp_str .. ')'
            tmp_str = nil
            return #self.cwhere
        end
        if ((operator == 'between' or operator == 'not between') and type(op2) ~= 'table' and type(op3) ~= 'table') then
            self.cwhere[#self.cwhere+1] = op1 .. self.where_operators[operator] .. '\'' .. tostring(op2)
            .. '\' AND \'' .. tostring(op3) .. '\''
            return #self.cwhere
        end
        if ((operator == 'like' or operator == 'not like') and type(op2) ~= 'table') then
            self.cwhere[#self.cwhere+1] = op1 .. self.where_operators[operator] .. '\'' .. tostring(op2) .. '\''
            return #self.cwhere
        end
    else
        return 'db:where(): operand1 must be a string and operand2 must be a string or table!'
    end
end

return sql
