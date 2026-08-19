/**
 * The server-side half of the Guideline 1.2 filter.
 *
 * The app screens before publishing too (ContentFilter in Moderation.swift), but a
 * client-side check is a courtesy, not a control — anyone can talk to this API with
 * curl. The rule that counts is the one enforced here.
 *
 * Keep the lists deliberately narrow. Broad keyword blocking produces false positives
 * that infuriate real sellers, and a seller who cannot list is a seller who leaves.
 */

const PROFANITY = [
  // Populate from a maintained list before launch, and INCLUDE ARABIC TERMS — an
  // English-only filter on a Qatar app is not a filter. Load it from here rather than
  // the app bundle so you can update it without shipping a build.
];

const OFF_PLATFORM = ['instagram.com', 'snapchat', '@gmail', '@hotmail', 't.me/'];

const COUNTERFEIT_SIGNALS = [
  'lepin', 'compatible bricks', 'not original', 'replica set', 'knockoff', 'bootleg',
];

export function evaluate({ title = '', note = '' }) {
  const text = `${title} ${note}`.toLowerCase();

  if (PROFANITY.some((term) => text.includes(term))) {
    return { verdict: 'reject', message: "Listings can't contain offensive language." };
  }
  if (OFF_PLATFORM.some((term) => text.includes(term))) {
    return {
      verdict: 'reject',
      message: 'Keep contact details out of the description — buyers reach you through the WhatsApp button.',
    };
  }
  if (COUNTERFEIT_SIGNALS.some((term) => text.includes(term))) {
    return {
      verdict: 'review',
      message: "This looks like it may not be genuine LEGO. We'll check it before it goes live.",
    };
  }
  return { verdict: 'allow', message: null };
}

/** 'live' publishes immediately, 'held' waits for a human in the moderation queue. */
export function statusForVerdict(verdict) {
  return verdict === 'review' ? 'held' : 'live';
}


// MARK: - Photo rules

/**
 * How many photos a listing needs.
 *
 * These count the seller's OWN photos. A listing with a set number also shows the
 * catalogue's standard image of that set first, but a stock photo is not evidence of
 * what is in someone's cupboard — the whole point is seeing the actual item.
 *
 * A built set needs two because "Built" means assembled and on display, and one
 * flattering angle of an assembled model hides exactly the damage a buyer is asking
 * about. Change these numbers here and the app picks them up from the error message.
 */
export const PHOTO_RULES = {
  min: 1,
  minWhenBuilt: 2,
  max: 3,
};

export function requiredPhotoCount(condition) {
  return condition === 'Built' ? PHOTO_RULES.minWhenBuilt : PHOTO_RULES.min;
}

export function checkPhotoCount({ condition, count }) {
  const required = requiredPhotoCount(condition);

  if (count < required) {
    return {
      ok: false,
      message: required === 1
        ? 'Add at least one photo of the actual item.'
        : "Built sets need at least two photos — buyers can't judge an assembled set from one angle.",
    };
  }
  if (count > PHOTO_RULES.max) {
    return { ok: false, message: `That is more than ${PHOTO_RULES.max} photos.` };
  }
  return { ok: true, message: null };
}
