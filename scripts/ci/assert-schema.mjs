import { readFile } from 'node:fs/promises';

function typeOfValue(value) {
  if (Array.isArray(value)) return 'array';
  if (value === null) return 'null';
  return typeof value;
}

function assertSchema(schema, value, path = '$') {
  if (schema.const !== undefined && value !== schema.const) {
    throw new Error(`${path}: expected const ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)}`);
  }

  if (schema.enum && !schema.enum.includes(value)) {
    throw new Error(`${path}: expected one of ${schema.enum.join(', ')}, got ${JSON.stringify(value)}`);
  }

  if (schema.type) {
    const actualType = typeOfValue(value);
    if (schema.type === 'number') {
      if (actualType !== 'number') throw new Error(`${path}: expected number, got ${actualType}`);
    } else if (actualType !== schema.type) {
      throw new Error(`${path}: expected ${schema.type}, got ${actualType}`);
    }
  }

  if (schema.required) {
    for (const key of schema.required) {
      if (!(key in value)) {
        throw new Error(`${path}: missing required key ${key}`);
      }
    }
  }

  if (schema.properties) {
    for (const [key, childSchema] of Object.entries(schema.properties)) {
      if (key in value) {
        assertSchema(childSchema, value[key], `${path}.${key}`);
      }
    }
  }

  if (schema.items) {
    if (!Array.isArray(value)) {
      throw new Error(`${path}: expected array for items validation`);
    }
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      throw new Error(`${path}: expected at least ${schema.minItems} items, got ${value.length}`);
    }
    for (let index = 0; index < value.length; index += 1) {
      assertSchema(schema.items, value[index], `${path}[${index}]`);
    }
  }
}

async function main() {
  const schemaPath = process.argv[2];
  if (!schemaPath) {
    throw new Error('usage: bun scripts/ci/assert-schema.mjs <schema-path>');
  }

  const [schemaText, inputText] = await Promise.all([
    readFile(schemaPath, 'utf8'),
    new Response(Bun.stdin.stream()).text()
  ]);

  const schema = JSON.parse(schemaText);
  const value = JSON.parse(inputText);
  assertSchema(schema, value);
}

await main();
