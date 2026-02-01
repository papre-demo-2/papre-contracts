#!/usr/bin/env node
/**
 * Prepare Terms of Service Bundler
 *
 * This script creates a ToS bundler for the Papre platform:
 * 1. Reads the ToS markdown from templates/tos/
 * 2. Uploads ToS markdown to IPFS via Storacha
 * 3. Creates bundler JSON with ToS document
 * 4. Uploads bundler to IPFS
 * 5. Outputs CID for papre-app .env configuration
 *
 * Requirements:
 * - STORACHA_KEY environment variable
 * - STORACHA_PROOF environment variable
 *
 * Usage:
 *   # Set environment variables from papre-app/.env.local or export them directly
 *   export STORACHA_KEY="..."
 *   export STORACHA_PROOF="..."
 *   node scripts/prepare-tos-bundler.js
 *
 *   # Or source from papre-app:
 *   source ../papre-app/.env.local && node scripts/prepare-tos-bundler.js
 */

import * as Client from '@web3-storage/w3up-client';
import { StoreMemory } from '@web3-storage/w3up-client/stores/memory';
import * as Signer from '@ucanto/principal/ed25519';
import * as Proof from '@web3-storage/w3up-client/proof';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration
const TOS_VERSION = '1.0';
const TOS_EFFECTIVE_DATE = '2025-01-12';
const TOS_FILENAME = 'papre-terms-of-service-v1.0.md';
const TOS_PATH = path.join(__dirname, '..', 'templates', 'tos', TOS_FILENAME);

/**
 * Initialize Storacha client
 */
async function getStorachaClient() {
  const key = process.env.STORACHA_KEY;
  const proof = process.env.STORACHA_PROOF;

  if (!key || !proof) {
    throw new Error(
      'STORACHA_KEY and STORACHA_PROOF environment variables must be set.\n' +
        'You can source these from papre-app/.env.local:\n' +
        '  source ../papre-app/.env.local && node scripts/prepare-tos-bundler.js'
    );
  }

  console.log('Initializing Storacha client...');

  // Parse the agent key
  const principal = Signer.parse(key);
  const store = new StoreMemory();

  // Create client with the pre-configured principal
  const client = await Client.create({ principal, store });

  // Parse and add the delegation proof
  const parsedProof = await Proof.parse(proof);
  const space = await client.addSpace(parsedProof);
  await client.setCurrentSpace(space.did());

  console.log('Storacha client initialized, space:', space.did());
  return client;
}

/**
 * Get the gateway URL for a CID
 */
function getGatewayUrl(cid) {
  return `https://${cid}.ipfs.w3s.link`;
}

/**
 * Upload a file to IPFS
 */
async function uploadFile(client, content, mimeType) {
  const blob = new Blob([content], { type: mimeType });
  const cid = await client.uploadFile(blob);
  return cid.toString();
}

/**
 * Main function
 */
async function main() {
  console.log('='.repeat(60));
  console.log('Papre Terms of Service Bundler Preparation');
  console.log('='.repeat(60));
  console.log();

  // Check if ToS file exists
  if (!fs.existsSync(TOS_PATH)) {
    throw new Error(`ToS file not found: ${TOS_PATH}`);
  }

  // Read ToS markdown
  console.log(`Reading ToS from: ${TOS_PATH}`);
  const tosContent = fs.readFileSync(TOS_PATH, 'utf-8');
  const tosSize = Buffer.byteLength(tosContent, 'utf-8');
  console.log(`ToS size: ${tosSize} bytes`);
  console.log();

  // Initialize Storacha client
  const client = await getStorachaClient();
  console.log();

  // Step 1: Upload ToS markdown to IPFS
  console.log('Step 1: Uploading ToS markdown to IPFS...');
  const tosCid = await uploadFile(client, tosContent, 'text/markdown');
  console.log(`ToS document CID: ${tosCid}`);
  console.log(`ToS gateway URL: ${getGatewayUrl(tosCid)}`);
  console.log();

  // Step 2: Create bundler JSON
  console.log('Step 2: Creating ToS bundler...');
  const bundler = {
    version: '1.0',
    type: 'terms-of-service',
    metadata: {
      title: 'Papre Platform Terms of Service',
      version: TOS_VERSION,
      effectiveDate: TOS_EFFECTIVE_DATE,
      createdAt: new Date().toISOString(),
    },
    documents: [
      {
        cid: tosCid,
        filename: TOS_FILENAME,
        mimeType: 'text/markdown',
        size: tosSize,
        role: 'terms-of-service',
      },
    ],
  };

  console.log('Bundler metadata:', JSON.stringify(bundler.metadata, null, 2));
  console.log();

  // Step 3: Upload bundler to IPFS
  console.log('Step 3: Uploading bundler to IPFS...');
  const bundlerJson = JSON.stringify(bundler, null, 2);
  const bundlerCid = await uploadFile(client, bundlerJson, 'application/json');
  console.log(`Bundler CID: ${bundlerCid}`);
  console.log(`Bundler gateway URL: ${getGatewayUrl(bundlerCid)}`);
  console.log();

  // Output results
  console.log('='.repeat(60));
  console.log('SUCCESS! ToS Bundler created and uploaded.');
  console.log('='.repeat(60));
  console.log();
  console.log('Add this to papre-app/.env.local:');
  console.log();
  console.log(`VITE_TOS_BUNDLER_CID=${bundlerCid}`);
  console.log();
  console.log('ToS document details:');
  console.log(`  CID: ${tosCid}`);
  console.log(`  URL: ${getGatewayUrl(tosCid)}`);
  console.log();
  console.log('Bundler details:');
  console.log(`  CID: ${bundlerCid}`);
  console.log(`  URL: ${getGatewayUrl(bundlerCid)}`);
  console.log();

  return bundlerCid;
}

// Run
main()
  .then((cid) => {
    console.log('Done!');
    process.exit(0);
  })
  .catch((err) => {
    console.error('Error:', err.message);
    process.exit(1);
  });
