/**
 * Puts the development listings from MockData (Catalog.swift) into the real database,
 * so Browse has something in it the first time you run the app against this server.
 *
 * Safe to re-run: it skips seeding if any listing already exists.
 *   npm run seed     seed if empty
 *   npm run reset    delete the database and seed from scratch
 */
import { db, now } from './db.js';
import * as repo from './repository.js';

const SELLERS = [
  { id: 'u1', displayName: 'Faisal',  whatsAppNumber: '97433124455', completedTrades: 24 },
  { id: 'u2', displayName: 'Maryam',  whatsAppNumber: '97455667788', completedTrades: 11 },
  { id: 'u3', displayName: 'Ibrahim', whatsAppNumber: '97466778899', completedTrades: 6 },
  { id: 'u4', displayName: 'Dana',    whatsAppNumber: '97477889900', completedTrades: 38 },
  { id: 'u5', displayName: 'Hessa',   whatsAppNumber: '97488990011', completedTrades: 9 },
];

const hoursAgo = (hours) => new Date(Date.now() - hours * 3_600_000).toISOString();

const LISTINGS = [
  {
    id: 'seed-1', sellerID: 'u1', type: 'set', setNumber: '10305', theme: 'Icons',
    title: "Lion Knights' Castle", condition: 'New', completeness: 8,
    includesInstructions: true, boxCondition: 'Mint', priceQAR: 2400,
    note: 'Bought two at launch. Never opened, stored flat in AC.',
    whatsAppNumber: '97433124455', createdAt: hoursAgo(48),
  },
  {
    id: 'seed-2', sellerID: 'u2', type: 'set', setNumber: '10497', theme: 'Icons',
    title: 'Galaxy Explorer', condition: 'Good condition', completeness: 8,
    includesInstructions: true, boxCondition: 'Good', priceQAR: 520,
    note: 'Built it, displayed it a year, took it apart. Every piece counted back against the inventory.',
    whatsAppNumber: '97455667788', createdAt: hoursAgo(5),
  },
  {
    id: 'seed-3', sellerID: 'u3', type: 'bulk', setNumber: null, theme: 'Mixed',
    title: 'Mixed bulk lot, 4.2 kg', condition: 'Poor condition', completeness: null,
    includesInstructions: false, boxCondition: null, priceQAR: 340,
    note: 'Kids grew out of it. All jumbled in one box, no sorting. Mostly City and Creator.',
    whatsAppNumber: '97466778899', createdAt: hoursAgo(24),
  },
  {
    id: 'seed-4', sellerID: 'u4', type: 'set', setNumber: '21318', theme: 'Ideas',
    title: 'Tree House', condition: 'Built', completeness: 7,
    includesInstructions: true, boxCondition: 'Fair', priceQAR: 1650,
    note: "Missing 6 leaf elements and one 1x2 tile. Listed below market because of it — I'd rather be honest than argue later.",
    whatsAppNumber: '97477889900', createdAt: hoursAgo(72),
  },
  {
    id: 'seed-5', sellerID: 'u1', type: 'minifigures', setNumber: null, theme: 'Star Wars',
    title: 'Star Wars minifigures, 14 figures', condition: 'Good condition', completeness: null,
    includesInstructions: false, boxCondition: null, priceQAR: 275,
    note: 'Fourteen figures, all authentic, all with correct accessories.',
    whatsAppNumber: '97433124455', createdAt: hoursAgo(96),
  },
  {
    id: 'seed-6', sellerID: 'u5', type: 'set', setNumber: '75341', theme: 'Star Wars',
    title: "Luke Skywalker's Landspeeder", condition: 'New', completeness: 8,
    includesInstructions: true, boxCondition: 'Mint', priceQAR: 1180,
    note: 'Sealed since release. Retired now, but I need the shelf space.',
    whatsAppNumber: '97488990011', createdAt: hoursAgo(12),
  },
];

const WANTED = [
  { id: 'w1', setNumber: '10276', theme: null, maxPriceQAR: 2600 },
  { id: 'w2', setNumber: '75313', theme: null, maxPriceQAR: 2800 },
  { id: 'w3', setNumber: null, theme: 'Technic', maxPriceQAR: 1200 },
];

export function seed({ force = false } = {}) {
  const existing = db.prepare('SELECT COUNT(*) AS count FROM listings').get().count;
  if (existing > 0 && !force) {
    console.log(`Database already has ${existing} listing(s) — nothing to seed.`);
    return { seeded: false };
  }

  for (const seller of SELLERS) repo.upsertDevUser(seller);

  // The dev user the app signs in as when RootView.skipSignIn is true.
  repo.upsertDevUser({
    id: 'dev-user', displayName: 'Faisal', whatsAppNumber: '97433124455', completedTrades: 24,
  });

  for (const listing of LISTINGS) {
    repo.insertListing({ ...listing, photoURLs: [], status: 'live' });
  }
  for (const item of WANTED) {
    repo.insertWanted('dev-user', { ...item, createdAt: now() });
  }

  console.log(`Seeded ${LISTINGS.length} listings, ${SELLERS.length + 1} users, ${WANTED.length} wanted entries.`);
  return { seeded: true };
}

// Run directly: node lib/seed.js
if (import.meta.url === `file://${process.argv[1]}`) {
  seed({ force: process.argv.includes('--force') });
  db.close();
}
