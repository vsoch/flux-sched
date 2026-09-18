/*****************************************************************************\
 * Copyright 2026 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, LICENSE)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\*****************************************************************************/

#ifndef QUEUE_POLICY_COSCHEDULE_IMPL_HPP
#define QUEUE_POLICY_COSCHEDULE_IMPL_HPP

#include "resource/policies/base/match_op.h"

#include "qmanager/policies/queue_policy_coschedule.hpp"
#include "qmanager/policies/queue_policy_bf_base_impl.hpp"

namespace Flux {
namespace queue_manager {
namespace detail {

template<class reapi_type>
queue_policy_coschedule_t<reapi_type>::~queue_policy_coschedule_t ()
{
}

template<class reapi_type>
int queue_policy_coschedule_t<reapi_type>::apply_params ()
{
    return queue_policy_base_t::apply_params ();
}

template<class reapi_type>
queue_policy_coschedule_t<reapi_type>::queue_policy_coschedule_t ()
{
    /* one reservation, as easy does. A group is reserved as a unit, so a
     * deeper reservation window would only block more space for longer.
     */
    queue_policy_bf_base_t<reapi_type>::m_reservation_depth = 1;
}

template<class reapi_type>
int queue_policy_coschedule_t<reapi_type>::next_match_iter ()
{
    using bf = queue_policy_bf_base_t<reapi_type>;

    if (bf::m_in_progress_iter == queue_policy_base_t::m_pending.end ())
        return bf::next_match_iter ();

    auto job_it = queue_policy_base_t::m_jobs.find (bf::m_in_progress_iter->second);
    if (job_it == queue_policy_base_t::m_jobs.end ())
        return bf::next_match_iter ();

    /* Held: reserve the footprint this cycle without ever allocating it, even
     * when it could be allocated now. The reservation is torn down at the top
     * of the next loop and re-made, so it blocks the space for this cycle only
     * and backfill packs around it. It stays reserved until the release RPC
     * clears the hold, at which point it is matched normally and allocates
     * from the front.
     *
     * This lives here rather than in the backfill base so that the other
     * policies are unaffected. A held job under easy, hybrid or conservative
     * is an ordinary job, because those policies do not support coscheduling.
     */
    if (job_it->second->hold) {
        json_t *spec = nullptr;
        json_error_t err;
        json_t *arr = nullptr;
        int rc;

        if (!(spec = json_loads (job_it->second->jobspec.c_str (), 0, &err))) {
            errno = ENOMEM;
            return -1;
        }
        if (!(arr = json_pack ("[{s:I s:o}]",
                               "jobid",
                               static_cast<json_int_t> (job_it->second->id),
                               "jobspec",
                               spec))) {
            json_decref (spec);
            errno = ENOMEM;
            return -1;
        }
        rc = reapi_type::match_allocate_multi (bf::m_handle, match_op_t::MATCH_RESERVE, arr, this);
        json_decref (arr);
        return rc;
    }

    return bf::next_match_iter ();
}

}  // namespace detail
}  // namespace queue_manager
}  // namespace Flux

#endif  // QUEUE_POLICY_COSCHEDULE_IMPL_HPP

/*
 * vi:tabstop=4 shiftwidth=4 expandtab
 */
