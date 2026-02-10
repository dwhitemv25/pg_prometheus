CREATE TYPE prom_sample_cx AS (
        metric text,
        value double precision,
        ts timestamptz,
        labels json
);

CREATE FUNCTION prom_escape(text)
    RETURNS text
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    RETURN replace(replace(replace($1,'\','\\'),'"','\"'),E'\n','\n');
    
COMMENT ON FUNCTION prom_escape(text) IS 'Escape Prometheus literals according to exposition format rules';

CREATE FUNCTION prom_unescape(text)
    RETURNS text
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    RETURN replace(replace(replace($1,'\n',E'\n'),'\"','"'),'\\','\');

COMMENT ON FUNCTION prom_unescape(text) is 'Unescape Prometheus literals according to exposition format rules';

CREATE FUNCTION prom_labels_to_expo(json)
    RETURNS text
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    BEGIN ATOMIC
    SELECT concat_ws(',', VARIADIC a) FROM (
        SELECT array_agg(concat_ws('=',format('"%s"',prom_escape(k)),format('"%s"',prom_escape(v)))) FROM json_each_text($1) t(k,v)
    ) s(a);
END;

COMMENT ON FUNCTION prom_labels_to_expo(json) IS 'Convert json in prom_sample_cx type to label exposition format (w/o brackets)';

CREATE FUNCTION prom_expo_to_labels(text)
    RETURNS json
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    BEGIN ATOMIC
    SELECT json_object(array_agg(ARRAY[a1, a2])) FROM (
        SELECT
        prom_unescape(trim(BOTH '"' FROM a[1])) AS a1,
        prom_unescape(trim(BOTH '"' FROM a[2])) AS a2 FROM (
            SELECT string_to_array(a, '=') FROM string_to_table(trim(BOTH '{},' FROM $1), ',') s(a)
        WHERE a IS NOT NULL) t(a)
    ) u;
    END;
    
COMMENT ON FUNCTION prom_expo_to_labels(text) IS 'Convert label exposition format to JSON';

CREATE FUNCTION prom_construct_cx(timestamptz, text, double precision, json)
    RETURNS prom_sample_cx
    PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    RETURN ROW($2, $3, $1, $4);
    
COMMENT ON FUNCTION prom_construct_cx(timestamptz, text, double precision, json) IS 'Create prom_sample_cx type from individual arguments';

CREATE FUNCTION prom_to_expo_classic(prom_sample_cx)
    RETURNS text
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    RETURN format('%s{%s} %s %s', $1.metric, prom_labels_to_expo($1.labels), $1.value, floor(extract(epoch from $1.ts)*1000));

COMMENT ON FUNCTION prom_to_expo_classic(prom_sample_cx) IS 'Convert prom_sample_cx type to exposition format with Prometheus identifier-compatible metric name';

CREATE FUNCTION prom_to_expo_utf8(prom_sample_cx)
    RETURNS text
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    RETURN format('{%s} %s %s', concat_ws(',', format('"%s"', prom_escape($1.metric)), prom_labels_to_expo($1.labels)), $1.value, floor(extract(epoch from $1.ts)*1000));
    
COMMENT ON FUNCTION prom_to_expo_utf8(prom_sample_cx) IS 'Convert prom_sample_cx type to exposition format with quoted/escaped metric name';

CREATE FUNCTION prom_from_expo_classic(text)
    RETURNS prom_sample_cx
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    BEGIN ATOMIC
    SELECT prom_construct_cx(to_timestamp(a[4]::double precision/1000.0::double precision), a[1]::text, a[3]::double precision, prom_expo_to_labels(a[2])) FROM
        regexp_match($1, '^([a-zA-Z_:][a-zA-Z0-9_:]*]*)?(\{.*\})?[\t ]*([-0-9E.]*)[\t ]*([0-9]+)?$'::text)
        r(a);
    END;
    
COMMENT ON FUNCTION prom_from_expo_classic(text) is 'Convert exposition format with Prometheus identifier-compatible metric name to prom_sample_cx type';

CREATE FUNCTION prom_from_expo_utf8(text)
    RETURNS prom_sample_cx
    STRICT PARALLEL SAFE IMMUTABLE
    LANGUAGE SQL
    BEGIN ATOMIC
    SELECT prom_construct_cx(to_timestamp(a[4]::double precision/1000.0::double precision), a[1]::text, a[3]::double precision, prom_expo_to_labels(a[2])) FROM
        regexp_match($1,'^\{\"([^,]+)\",?(.+)?\}[\t ]*([-0-9E.]*)[\t ]*([0-9]+)?$')
        r(a);
    END;
    
COMMENT ON FUNCTION prom_from_expo_classic(text) is 'Convert exposition format with quoted/escaped metric name to prom_sample_cx type';


CREATE FUNCTION insert_view_normalized_cx()
    RETURNS TRIGGER LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    new_cx            prom_sample_cx;
    labels_table      name;
    values_table      name;
    to_append         text[];
    labels_array      text[];
    append_labels     text[] = current_setting('pg_prometheus_cx.append_labels');
    remove_labels     text[] = current_setting('pg_prometheus_cx.remove_labels');
    instance_label    text = current_setting('pg_prometheus_cx.instance_label');
    job_label         text = current_setting('pg_prometheus_cx.job_label');
BEGIN
    IF TG_NARGS != 2 THEN
        RAISE EXCEPTION 'insert_view_normal requires 2 parameters';
    END IF;

    values_table := TG_ARGV[0];
    labels_table := TG_ARGV[1];
    
    IF NEW.sample ^@ '{' THEN
        new_cx = prom_from_expo_utf8(NEW.sample);
    ELSE
        new_cx = prom_from_expo_classic(NEW.sample);
    END IF;
    
    IF instance_label <> '' THEN
        to_append := to_append || ARRAY[ARRAY['instance', instance_label]]::text[];
    END IF;
    IF job_label <> '' THEN
        to_append := to_append || ARRAY[ARRAY['job', job_label]]::text[];
    END IF;
    IF to_append IS NOT NULL OR array_length(remove_labels, 1) > 0 THEN
        SELECT array_agg(a) FROM json_each_text(new_cx.labels) j(a)
        WHERE NOT a[1] =ANY(remove_labels)
        INTO labels_array;
        labels_array := labels_array || to_append;
        new_cx.labels = json_object(labels_array);
    END IF;
    
    EXECUTE format($$
        WITH
        data AS (SELECT
            (p).metric AS p_name,
            COALESCE((p).labels::jsonb,'{}'::jsonb) AS p_labels,
            (p).ts AS p_time,
            (p).value AS p_value
            FROM
                (VALUES ($1)) v(p)
        ),
        ins AS (INSERT INTO %I (metric_name, labels) SELECT p_name, p_labels FROM data d ON CONFLICT DO NOTHING RETURNING *)
        INSERT INTO %I (ts, value, labels_id)
        SELECT d.p_time, d.p_value, coalesce(ins.id, lt.id) FROM data d
        LEFT JOIN %I lt ON d.p_name=lt.metric_name AND d.p_labels=lt.labels
        LEFT JOIN ins ON d.p_name=ins.metric_name AND d.p_labels=ins.labels
        $$,
        labels_table,
        values_table,
        labels_table
        ) USING (new_cx);


    RETURN NULL;
END
$BODY$;

CREATE FUNCTION create_prometheus_cx_table(
       metrics_view_name NAME,
       metrics_values_table_name NAME = NULL,
       metrics_labels_table_name NAME = NULL,
       metrics_samples_table_name NAME = NULL,
       metrics_copy_table_name NAME = NULL
)
    RETURNS BOOLEAN LANGUAGE PLPGSQL VOLATILE AS
$BODY$
BEGIN
    IF metrics_view_name IS NULL THEN
       RAISE EXCEPTION 'Must specify base name for tables';
    END IF;

    IF metrics_values_table_name IS NULL THEN
       metrics_values_table_name := format('%I_values', metrics_view_name);
    END IF;

    IF metrics_labels_table_name IS NULL THEN
       metrics_labels_table_name := format('%I_labels', metrics_view_name);
    END IF;

    IF metrics_samples_table_name IS NULL THEN
       metrics_samples_table_name := format('%I_samples', metrics_view_name);
    END IF;

    IF metrics_copy_table_name IS NULL THEN
       metrics_copy_table_name := format('%I_copy', metrics_view_name);
    END IF;

    -- Create labels table
    EXECUTE format(
        $$
        CREATE TABLE %I (
                  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                  metric_name text NOT NULL,
                  labels jsonb,
                  UNIQUE(metric_name, labels)
        )
        $$,
        metrics_labels_table_name
    );

    -- Create copy table
    EXECUTE format(
      $$
      CREATE TABLE %I (sample text NOT NULL)
      $$,
      metrics_copy_table_name
    );

    -- Create value table
    EXECUTE format(
        $$
        CREATE TABLE %I (
            ts timestamptz,
            value double precision,
            labels_id bigint REFERENCES %I(id)
        )
        $$,
        metrics_values_table_name,
        metrics_labels_table_name
    );

    -- Create labels ID column index
    EXECUTE format(
        $$
        CREATE INDEX %I_labels_id_idx ON %1$I USING BTREE (labels_id, ts desc)
        $$,
        metrics_values_table_name
    );

    -- Create a view for the metrics
    EXECUTE format(
        $$
        CREATE VIEW %I AS
        SELECT prom_construct(m.ts, l.metric_name, m.value, l.labels) AS sample,
               m.ts AS ts, l.metric_name AS metric, m.value AS value, l.labels AS labels
        FROM %I AS m
        INNER JOIN %I l ON (m.labels_id = l.id)
        $$,
        metrics_view_name,
        metrics_values_table_name,
        metrics_labels_table_name
    );

    -- Attach triggers for insert
    EXECUTE format(
        $$
        CREATE TRIGGER insert_trigger INSTEAD OF INSERT ON %I
        FOR EACH ROW EXECUTE PROCEDURE insert_view_normalized_cx(%L, %L)
        $$,
        metrics_view_name,
        metrics_values_table_name,
        metrics_labels_table_name
    );

    EXECUTE format(
        $$
        CREATE TRIGGER insert_trigger BEFORE INSERT ON %I
        FOR EACH ROW EXECUTE PROCEDURE insert_view_normalized_cx(%L, %L)
        $$,
        metrics_copy_table_name,
        metrics_values_table_name,
        metrics_labels_table_name
    );

    RETURN TRUE;
END
$BODY$;
