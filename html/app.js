(function () {
    const orderCard      = document.getElementById('orderCard');
    const cardTimer      = orderCard.querySelector('.card-timer');
    const cardFill       = orderCard.querySelector('.card-progress-fill');
    const restaurantEl   = orderCard.querySelector('.restaurant');
    const distanceEl     = orderCard.querySelector('.distance');
    const modeEl         = orderCard.querySelector('.mode');
    const itemsList      = document.getElementById('itemsList');

    const ratingOverlay  = document.getElementById('ratingOverlay');
    const ratingPayout   = document.getElementById('ratingPayout');
    const ratingQuote    = document.getElementById('ratingQuote');
    const ratingStars    = document.getElementById('ratingStars');
    const tierLabelEl    = document.getElementById('tierLabel');
    const avgRatingEl    = document.getElementById('avgRating');
    const totalDelEl     = document.getElementById('totalDeliveries');
    const ratingTimeEl   = document.getElementById('ratingTime');

    let totalSec = 60;

    function formatTime(sec) {
        if (sec < 0) sec = 0;
        const m = Math.floor(sec / 60);
        const s = sec % 60;
        return `${m}:${s.toString().padStart(2, '0')}`;
    }

    function applyTimer(timeLeftSec, expectedSec) {
        cardTimer.textContent = formatTime(timeLeftSec);
        cardTimer.classList.remove('warn', 'critical');
        cardFill.classList.remove('warn', 'crit');

        if (expectedSec > 0) {
            const pct = Math.max(0, (timeLeftSec / expectedSec) * 100);
            cardFill.style.width = pct + '%';
        }

        if (timeLeftSec <= 5)       { cardTimer.classList.add('critical'); cardFill.classList.add('crit'); }
        else if (timeLeftSec <= 20) { cardTimer.classList.add('warn');     cardFill.classList.add('warn'); }
    }

    function renderStars(stars) {
        // stars is float 1.0..5.0, may be .5
        ratingStars.innerHTML = '';
        const full = Math.floor(stars);
        const hasHalf = (stars - full) >= 0.5;
        for (let i = 1; i <= 5; i++) {
            const span = document.createElement('span');
            span.className = 'star';
            span.textContent = '★';
            if (i <= full) {
                span.classList.add('filled');
                span.style.animationDelay = ((i - 1) * 80) + 'ms';
            } else if (i === full + 1 && hasHalf) {
                span.classList.add('half');
            }
            ratingStars.appendChild(span);
        }
    }

    function showOrderCard(data) {
        orderCard.classList.remove('hidden', 'fading');

        restaurantEl.textContent = data.restaurantLabel || '—';
        distanceEl.textContent = (data.distance || 0) + ' m';

        if (data.walkOnly) {
            modeEl.textContent = 'Walk OK';
            modeEl.classList.remove('vehicle');
        } else {
            modeEl.textContent = 'Vehicle';
            modeEl.classList.add('vehicle');
        }

        // Items list
        itemsList.innerHTML = '';
        (data.items || []).forEach(text => {
            const li = document.createElement('li');
            li.textContent = text;
            itemsList.appendChild(li);
        });

        totalSec = data.expectedSec || 60;
        applyTimer(totalSec, totalSec);
    }

    function hideOrderCard() {
        orderCard.classList.add('fading');
        setTimeout(() => {
            orderCard.classList.add('hidden');
            orderCard.classList.remove('fading');
        }, 400);
    }

    function showRating(data) {
        ratingPayout.textContent = '+$' + (data.payout || 0).toLocaleString();
        ratingQuote.textContent = '"' + (data.quote || '...') + '"';
        renderStars(data.stars || 5);
        tierLabelEl.textContent = data.newTierLabel || 'Standard';
        tierLabelEl.dataset.tier = data.newTierLabel || 'Standard';
        avgRatingEl.textContent = (data.newAverage ? data.newAverage.toFixed(2) : '5.00') + '★';
        totalDelEl.textContent = data.newDeliveries || 0;
        ratingTimeEl.textContent = formatTime(data.elapsedSec || 0) + ' / ' + formatTime(data.expectedSec || 0);

        ratingOverlay.classList.remove('hidden', 'fading');

        // Auto-dismiss after 8s
        setTimeout(() => {
            ratingOverlay.classList.add('fading');
            setTimeout(() => {
                ratingOverlay.classList.add('hidden');
                ratingOverlay.classList.remove('fading');
                hideOrderCard();
            }, 400);
        }, 8000);
    }

    window.addEventListener('message', function (event) {
        const data = event.data || {};
        const action = data.action;

        if (action === 'show')   showOrderCard(data);
        if (action === 'hide')   hideOrderCard();
        if (action === 'tick') {
            if (typeof data.distanceM === 'number') {
                distanceEl.textContent = data.distanceM + ' m';
            }
            if (typeof data.timeLeftSec === 'number') {
                applyTimer(data.timeLeftSec, data.expectedSec || totalSec);
            }
        }
        if (action === 'rating') showRating(data);
        if (action === 'hideAll') {
            orderCard.classList.add('hidden');
            ratingOverlay.classList.add('hidden');
        }
    });
})();
