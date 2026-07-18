/*****************************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, LICENSE)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\*****************************************************************************/

#ifndef QUEUE_POLICY_COSCHEDULE_HPP
#define QUEUE_POLICY_COSCHEDULE_HPP

#include "qmanager/policies/queue_policy_bf_base.hpp"

namespace Flux {
namespace queue_manager {
namespace detail {

/* Place jobs that have to run together, together.
 *
 * Backfill reserves a held job's footprint and packs around it, which is right
 * for a single job but not for a pair. Reserving for one member says nothing
 * about the other, so the reservation for one half can consume the last free
 * cores and leave nothing for its partner. Neither can then proceed.
 *
 * A member declares its group in its jobspec:
 *
 *   attributes.system.coschedule = { "group": "<id>", "size": n, "op": "..." }
 *
 * The group is matched only once every member is pending, and then as a unit:
 * every member is placed or none is. op says what to do with each member, so a
 * member that should run is allocated while a member that should be placed but
 * not started, released later by some external agent, is reserved.
 *
 * Nothing here is specific to any kind of resource. A pair needing a licence,
 * a tape mount or an instrument has the same shape as one needing a QPU.
 *
 * Jobs with no coschedule attribute are scheduled exactly as backfill would.
 */
template<class reapi_type>
class queue_policy_coschedule_t : public queue_policy_bf_base_t<reapi_type> {
   public:
    virtual ~queue_policy_coschedule_t ();
    queue_policy_coschedule_t ();
    queue_policy_coschedule_t (const queue_policy_coschedule_t &p) = default;
    queue_policy_coschedule_t (queue_policy_coschedule_t &&p) = default;
    queue_policy_coschedule_t &operator= (const queue_policy_coschedule_t &p) = default;
    queue_policy_coschedule_t &operator= (queue_policy_coschedule_t &&p) = default;
    int apply_params () override;
    const std::string_view policy () const override
    {
        return "coschedule";
    }

   protected:
    /* Reserve a held job every cycle instead of allocating it, so it keeps its
     * footprint until an external agent releases it. Everything else is
     * backfill.
     */
    int next_match_iter () override;
};

}  // namespace detail
}  // namespace queue_manager
}  // namespace Flux

#endif  // QUEUE_POLICY_COSCHEDULE_HPP

/*
 * vi:tabstop=4 shiftwidth=4 expandtab
 */
