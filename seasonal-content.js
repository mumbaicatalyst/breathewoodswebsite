(() => {
  // Leave blank for the calendar-driven season. Set to winter, summer, monsoon,
  // or postMonsoon when weather conditions call for a temporary manual override.
  const manualSeason = ''

  const seasons = {
    winter: {
      label: 'Winter at Breathe Woods',
      hero: [
        { eyebrow: 'Winter at Breathe Woods', title: 'A slower stay shaped by water and woods.', detail: 'Six and a half acres. Two private villas.', image: 'Pics/seasonal/winter/aerial-winter.png', mobileImage: 'Pics/seasonal/winter-mobile/aerial-winter.png', alt: 'Aerial winter view of Breathe Woods, surrounded by water and forest' },
        { eyebrow: 'Cooler evenings', title: 'Stay out a little longer.', detail: 'Bonfire and barbecue arrangements available on request.', image: 'Pics/optimized/home/home-page-nature-pause.jpg', mobileImage: 'Pics/optimized/home-mobile/home-page-nature-pause.jpg', alt: 'A quiet green path at Breathe Woods' },
        { eyebrow: 'Unhurried mornings', title: 'Let the day begin slowly.', detail: 'Breakfast, a walk and nowhere else you need to be.', image: 'Pics/seasonal/winter/morning-winter.png', mobileImage: 'Pics/seasonal/winter-mobile/morning-winter.png', alt: 'Clear winter morning light over the Breathe Woods garden' },
        { eyebrow: 'Two private villas', title: 'Your place in the woods.', detail: 'Space to settle in with the people—and pets—you brought along.', image: 'Pics/seasonal/winter/villa-winter.png', mobileImage: 'Pics/seasonal/winter-mobile/villa-winter.png', alt: 'A Breathe Woods villa in clear winter light' },
        { eyebrow: 'Time together', title: 'Make the evenings count.', detail: 'Good food, warm drinks and a few days without a fixed agenda.', image: 'Pics/optimized/home/hero-relax-people.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-relax-people.jpg', alt: 'Two guests sitting with warm drinks on a Breathe Woods porch' }
      ],
      introNote: 'Cooler evenings make room for moonlit walks, long dinners and slow time together.',
      experience: {
        eyebrow: 'The winter pause',
        title: 'Stay out a little longer.',
        body: 'Cooler evenings, moonlit walks, good food and quiet time with the people—and pets—you brought along.',
        image: 'Pics/optimized/home/hero-relax-people.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-relax-people.jpg', alt: 'Guests relaxing with warm drinks at Breathe Woods'
      },
      breakfast: 'Start with a generous, home-style breakfast, then take the day slowly—perhaps with a walk, a book or a sunset by the lake.',
      closing: {
        eyebrow: 'A winter escape', title: 'Make the evenings count.',
        body: 'Choose your dates and settle into a few days of nature, space and unhurried time together.',
        image: 'Pics/optimized/home/home-page-nature-pause.jpg', mobileImage: 'Pics/optimized/home-mobile/home-page-nature-pause.jpg', alt: 'A lush, quiet path through greenery at Breathe Woods'
      },
      pages: {
        stays: {
          'stays-hero-eyebrow': 'Winter stays at Breathe Woods',
          'stays-hero-title': 'Cooler evenings. More time together.',
          'stays-hero-body': 'Two villas, five bedrooms, and room for a winter stay that feels like your own.',
          'stays-intro': 'Winter is a good time to settle into the property, take the evenings slowly and choose the space that suits your group.',
          images: { 'stays-hero': { image: 'Pics/seasonal/winter/villa-winter.png', alt: 'A Breathe Woods villa in clear winter light' } }
        },
        property: {
          'property-intro-title': 'More room for winter days.',
          'property-intro-body': 'Spread out, slow down and make the most of the open landscape. Cooler evenings leave room for a walk, a long meal or a bonfire arranged in advance.',
          'property-dining-body': 'When the evening cools, By the Bruk keeps good food close—breakfast, lunch and dinner without needing to leave the property.',
          'property-season-eyebrow': 'Winter at the lake',
          'property-season-title': 'Lake evenings, slower skies.',
          'property-season-body': 'In the cooler months, spend time by the nearby lake or watch the sun settle over the surrounding hills. Water outings remain subject to local conditions and on-ground guidance.'
        },
        dining: {
          'dining-hero-eyebrow': 'Winter at By the Bruk',
          'dining-hero-title': 'Good food, slower evenings.',
          'dining-hero-body': 'Breakfast, lunch and dinner for days that do not need to be rushed.',
          'dining-intro-body': 'By the Bruk is our on-site restaurant, where local Maharashtrian flavours, seasonal ingredients and unhurried meals come together. In winter, it is an easy place to linger over another cup of chai or a long dinner.',
          'dining-evening-title': 'Dinner, with nowhere else to be.',
          'dining-evening-body': 'As the evening cools, the lamps come on, the gardens grow quiet and dinner can take its own sweet time.'
        },
        explore: {
          'explore-hero-eyebrow': 'Explore winter at Breathe Woods',
          'explore-hero-title': 'Make the evening part of the stay.',
          'explore-hero-body': 'Take a walk while the light is soft, share time by the water or arrange a bonfire and barbecue for later.',
          'explore-fire-title': 'Firelight, then dinner.',
          'explore-fire-body': 'Bonfire and barbecue are paid add-ons, available by advance arrangement and when the weather allows—an easy way to make a cooler evening feel special.',
          images: { 'explore-hero': { image: 'Pics/Explore/Friends_gathering_around_bonfire.jpg', alt: 'Friends gathered around a bonfire at Breathe Woods' } }
        },
        information: {
          'information-hero-eyebrow': 'Planning a winter stay',
          'information-hero-title': 'Bring a light layer.<br>Leave room in the day.',
          'information-hero-body': 'Here is the practical part: arrival, meals, cooler evenings and a rough sense of the journey. Once you are here, the plan can loosen.',
          'information-season-title': 'Winter has its own reason.',
          'information-season-body': 'Winter brings comfortable days, cooler evenings, open space and time for walks, lake views, good food and a bonfire or barbecue arranged in advance.',
          'information-weather-title': 'Cooler days, warmer evenings.',
          'information-weather-body': 'Bring a light layer for after sunset. Bonfire, barbecue and lake outings are available by arrangement and remain subject to local conditions and on-ground guidance.',
          'information-packing-title': 'Pack for cooler evenings.',
          'information-packing-body': 'Comfortable shoes and a light layer will take you far. Bring anything your pet needs, and leave room for slow mornings and time outdoors.'
        },
        contact: {
          'contact-hero-eyebrow': 'Winter enquiries',
          'contact-hero-title': 'Let’s plan<br>your winter escape.',
          'contact-hero-body': 'Tell us your dates, group and what kind of winter stay you have in mind. We will help with the details, personally.',
          'contact-enquiry-title': 'A good winter stay starts with a simple hello.',
          'contact-enquiry-body': 'Share your preferred dates, group size and whether you would like to ask about a bonfire, barbecue, meals or a pet-friendly stay.'
        }
      }
    },
    summer: {
      label: 'Summer at Breathe Woods',
      hero: [
        { eyebrow: 'Summer at Breathe Woods', title: 'Start early. Leave the afternoon open.', detail: 'Six and a half acres. Two private villas.', image: 'Pics/optimized/home/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', alt: 'Aerial view of Breathe Woods, surrounded by water and forest' },
        { eyebrow: 'By the lake', title: 'Find the water when the light softens.', detail: 'Lake time with life vests, when water levels and conditions permit.', image: 'Pics/Explore/Family_picnicking_by_lake.jpg', mobileImage: 'Pics/Explore/Family_picnicking_by_lake.jpg', alt: 'Guests spending time beside the lake near Breathe Woods' },
        { eyebrow: 'Early mornings', title: 'Start before the heat.', detail: 'Walk the property, return for breakfast and take the afternoon at your pace.', image: 'Pics/optimized/home/hero-morning.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-morning.jpg', alt: 'Morning light over the Breathe Woods garden' },
        { eyebrow: 'Shaded pauses', title: 'Keep the afternoon easy.', detail: 'A verandah, a book and room to be together.', image: 'Pics/BougainVilla/bouganvillaporch.jpg', mobileImage: 'Pics/BougainVilla/bouganvillaporch.jpg', alt: 'A shaded villa verandah at Breathe Woods' },
        { eyebrow: 'Time together', title: 'Escape the city rush.', detail: 'Good food, green space and a slower family stay.', image: 'Pics/optimized/home/main-page-pets.jpg', mobileImage: 'Pics/optimized/home-mobile/main-page-pets.jpg', alt: 'A pet enjoying the green grounds at Breathe Woods' }
      ],
      introNote: 'A spacious summer stay for early walks, shaded verandahs and afternoons without a plan.',
      experience: {
        eyebrow: 'Unhurried days', title: 'Let the day open slowly.',
        body: 'Walk the property early, return for a generous meal and let the warmer hours pass in the shade.',
        image: 'Pics/BougainVilla/bouganvillaporch.jpg', mobileImage: 'Pics/BougainVilla/bouganvillaporch.jpg', alt: 'A shaded villa verandah at Breathe Woods'
      },
      breakfast: 'Start with a generous, home-style breakfast, then choose the shade, the lake or a quiet corner for the warmer hours.',
      closing: {
        eyebrow: 'A slower summer', title: 'Leave room in the day.',
        body: 'Choose your dates and make space for early walks, shaded afternoons and time with the people you love.',
        image: 'Pics/Explore/Family_picnicking_by_lake.jpg', mobileImage: 'Pics/Explore/Family_picnicking_by_lake.jpg', alt: 'Guests spending time beside the lake near Breathe Woods'
      },
      pages: {
        stays: {
          'stays-hero-eyebrow': 'Summer stays at Breathe Woods',
          'stays-hero-title': 'Start early. Leave the afternoon open.',
          'stays-hero-body': 'Two villas, five bedrooms, and room for a summer stay that moves at your pace.',
          'stays-intro': 'Make the most of the cooler mornings, generous breakfasts, shaded verandahs and long, unplanned afternoons around the property.',
          images: { 'stays-hero': { image: 'Pics/optimized/home/hero-morning.jpg', alt: 'Morning light over the Breathe Woods garden' } }
        },
        property: {
          'property-intro-title': 'Make the most of the open space.',
          'property-intro-body': 'Begin early, find a shaded corner and let the warmer part of the day pass without a packed schedule. There is room here to do less.',
          'property-dining-body': 'Long breakfasts and easy lunches are close at hand. By the Bruk keeps the day simple when you would rather stay on the property.',
          'property-season-eyebrow': 'Summer by the lake',
          'property-season-title': 'Stay with the light.',
          'property-season-body': 'Take the morning outside, return for a slower meal and enjoy the lake when the light softens. Lake swimming with life vests is possible only when water levels and conditions permit.'
        },
        dining: {
          'dining-hero-eyebrow': 'Summer at By the Bruk',
          'dining-hero-title': 'Breakfasts that take their time.',
          'dining-hero-body': 'Fresh, home-style meals for early starts, shaded afternoons and easy evenings.',
          'dining-intro-body': 'By the Bruk is our on-site restaurant, where local Maharashtrian flavours, seasonal ingredients and unhurried meals come together. Start early, eat well and leave the middle of the day open.',
          'dining-evening-title': 'Dinner after the light softens.',
          'dining-evening-body': 'As the heat of the day fades, the lamps come on and dinner becomes the gentlest way to finish a long, open day.'
        },
        explore: {
          'explore-hero-eyebrow': 'Explore summer at Breathe Woods',
          'explore-hero-title': 'Follow the cooler hours.',
          'explore-hero-body': 'Walk early, find the shade, ask about the lake conditions and save the longer conversations for evening.',
          'explore-fire-title': 'Stay for the evening.',
          'explore-fire-body': 'Bonfire and barbecue are paid add-ons, available by advance arrangement and when the weather allows—best enjoyed once the day begins to cool.',
          images: { 'explore-hero': { image: 'Pics/Explore/Family_picnicking_by_lake.jpg', alt: 'Family enjoying time by the lake near Breathe Woods' } }
        },
        information: {
          'information-hero-eyebrow': 'Planning a summer stay',
          'information-hero-title': 'Start early.<br>Take the afternoon slowly.',
          'information-hero-body': 'Here is the practical part: arrival, meals, warmer afternoons and a rough sense of the journey. Once you are here, the plan can loosen.',
          'information-season-title': 'Summer has its own rhythm.',
          'information-season-body': 'Summer is for early walks, long breakfasts, shaded pauses and open evenings. Lake swimming with life vests may be available when water levels and conditions permit.',
          'information-weather-title': 'Follow the cooler hours.',
          'information-weather-body': 'Comfortable shoes, sunscreen and a hat are useful. Bonfire, barbecue and lake outings are available by arrangement and remain subject to local conditions and on-ground guidance.',
          'information-packing-title': 'Pack light and breathable.',
          'information-packing-body': 'Bring comfortable clothes, sun protection, shoes for walking and anything your pet needs. Towels and essential toiletries are provided.'
        },
        contact: {
          'contact-hero-eyebrow': 'Summer enquiries',
          'contact-hero-title': 'Let’s plan<br>your slower summer.',
          'contact-hero-body': 'Tell us your dates, group and whether you are looking for early mornings, open afternoons or a quiet villa stay.',
          'contact-enquiry-title': 'A good summer stay starts with a simple hello.',
          'contact-enquiry-body': 'Share your preferred dates, group size and whether you would like to ask about meals, a lake outing or a pet-friendly stay.'
        }
      }
    },
    monsoon: {
      label: 'Monsoon at Breathe Woods',
      hero: [
        { eyebrow: 'Monsoon at Breathe Woods', title: 'A stay shaped by water, woods, and unhurried days.', detail: 'Six and a half acres. Two private villas.', image: 'Pics/optimized/home/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', alt: 'Aerial view of Breathe Woods, surrounded by water and forest' },
        { eyebrow: 'Raigad’s rain-fed land', title: 'Where water shapes the land.', detail: 'Follow the green when the rain eases.', image: 'Pics/optimized/home/hero-waterfall-new.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-waterfall-new.jpg', alt: 'Waterfall flowing through the monsoon-green landscape near Breathe Woods' },
        { eyebrow: 'Covered verandahs', title: 'Watch the rain change the view.', detail: 'A generous breakfast, a quiet table and nowhere else to be.', image: 'Pics/BougainVilla/bouganvillaporch.jpg', mobileImage: 'Pics/BougainVilla/bouganvillaporch.jpg', alt: 'A covered villa verandah at Breathe Woods' },
        { eyebrow: 'Two private villas', title: 'Your place in the green.', detail: 'Return to the warmth and quiet of your villa.', image: 'Pics/optimized/home/hero-villa.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-villa.jpg', alt: 'A Breathe Woods villa in the rain' },
        { eyebrow: 'Rain and good food', title: 'Make time to sit awhile.', detail: 'Listen to the rain, share a meal and let the woods set the pace.', image: 'Pics/Food/nightrestaurant.jpg', mobileImage: 'Pics/Food/nightrestaurant.jpg', alt: 'The restaurant at Breathe Woods in the evening' }
      ],
      introNote: 'Rain-fed greens, flowing water and a stay that invites you to slow down indoors and out.',
      experience: {
        eyebrow: 'Raigad in the rain', title: 'Follow the water.',
        body: 'Watch the landscape turn green, enjoy the rain from a covered verandah and ask the team what is comfortable outdoors that day.',
        image: 'Pics/BougainVilla/bouganvillaporch.jpg', mobileImage: 'Pics/BougainVilla/bouganvillaporch.jpg', alt: 'A covered villa verandah at Breathe Woods'
      },
      breakfast: 'Start with a generous, home-style breakfast, then watch the rain, follow the green or settle in for a quiet morning.',
      closing: {
        eyebrow: 'A rain-fed escape', title: 'Come away to the green.',
        body: 'Choose your dates and let the rain, water and woods set the pace of your stay.',
        image: 'Pics/optimized/home/home-page-follow-the-green.jpg', mobileImage: 'Pics/optimized/home-mobile/home-page-follow-the-green.jpg', alt: 'Guests walking a green rain-fed trail near Breathe Woods'
      },
      pages: {
        stays: {
          'stays-hero-eyebrow': 'Monsoon stays at Breathe Woods',
          'stays-hero-title': 'Come away to the green.',
          'stays-hero-body': 'Two villas, five bedrooms, and a rain-fed landscape that rewards slowing down.',
          'stays-intro': 'Choose a villa, watch the weather change and let the property become the plan for the day.',
          images: { 'stays-hero': { image: 'Pics/optimized/home/hero-waterfall-new.jpg', alt: 'Waterfall flowing through the monsoon-green landscape near Breathe Woods' } }
        },
        property: {
          'property-intro-title': 'When the water returns.',
          'property-intro-body': 'Rain-fed streams, deeper greens and the sound of water changing the landscape. Take the day as it comes, indoors and out.',
          'property-dining-body': 'When the rain arrives, By the Bruk keeps good food and warm drinks close—breakfast, lunch and dinner without a drive.',
          'property-season-eyebrow': 'Monsoon',
          'property-season-title': 'Where water shapes the land.',
          'property-season-body': 'Natural streams and rocky cascades become seasonal waterfalls. Conditions change with rainfall, so ask the team what is best and safest on the day.'
        },
        dining: {
          'dining-hero-eyebrow': 'Monsoon at By the Bruk',
          'dining-hero-title': 'A warm table after the rain.',
          'dining-hero-body': 'Local flavours, generous meals and another cup of chai while the landscape turns green.',
          'dining-intro-body': 'By the Bruk is our on-site restaurant, where local Maharashtrian flavours, seasonal ingredients and unhurried meals come together. During the rains, it is a good place to settle in while the weather moves around you.',
          'dining-evening-title': 'Dinner while the rain settles.',
          'dining-evening-body': 'The lamps come on, the gardens grow quiet and the evening becomes a softer place to wait out the weather.'
        },
        explore: {
          'explore-hero-eyebrow': 'Explore the rain-fed landscape',
          'explore-hero-title': 'Follow the green.',
          'explore-hero-body': 'Take a quiet walk when the rain eases, watch the streams move and return to the warmth of your villa.',
          'explore-fire-title': 'When the weather allows.',
          'explore-fire-body': 'Bonfire and barbecue are paid add-ons, available by advance arrangement. During heavy rain, the team may adjust or postpone them for comfort and safety.',
          images: { 'explore-hero': { image: 'Pics/Explore/explore-hero-trail.png', alt: 'Guests walking through a forest stream trail near Breathe Woods' } }
        },
        information: {
          'information-hero-eyebrow': 'Planning a monsoon stay',
          'information-hero-title': 'Bring rain shoes.<br>Leave room for the weather.',
          'information-hero-body': 'Here is the practical part: arrival, meals, rain-fed landscapes and a rough sense of the journey. Road and outdoor conditions can change.',
          'information-season-title': 'Monsoon changes the place.',
          'information-season-body': 'Streams and waterfalls are rain-fed and seasonal. Watch the weather, take walks when conditions are comfortable and let the team guide you on the day.',
          'information-weather-title': 'Let the weather lead.',
          'information-weather-body': 'Bring rain gear and shoes with grip. Bonfire, barbecue and lake outings may be adjusted or postponed during heavy rain for comfort and safety.',
          'information-packing-title': 'Pack for rain and muddy paths.',
          'information-packing-body': 'Bring rainwear, shoes with grip, a change of clothes and anything your pet needs. Towels and essential toiletries are provided.'
        },
        contact: {
          'contact-hero-eyebrow': 'Monsoon enquiries',
          'contact-hero-title': 'Let’s plan<br>a rain-fed escape.',
          'contact-hero-body': 'Tell us your dates, group and how comfortable you are letting the weather shape the stay. We will help with the details.',
          'contact-enquiry-title': 'A good monsoon stay starts with a simple hello.',
          'contact-enquiry-body': 'Share your dates, group size and any questions about road conditions, meals, pets or weather-dependent experiences.'
        }
      }
    },
    postMonsoon: {
      label: 'Post-monsoon at Breathe Woods',
      hero: [
        { eyebrow: 'After the rains', title: 'A stay surrounded by full green space.', detail: 'Six and a half acres. Two private villas.', image: 'Pics/optimized/home/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', alt: 'Aerial view of Breathe Woods, surrounded by water and forest' },
        { eyebrow: 'The green stays', title: 'Take the longer route.', detail: 'Open skies, quiet trails and time to explore the property.', image: 'Pics/optimized/home/home-page-follow-the-green.jpg', mobileImage: 'Pics/optimized/home-mobile/home-page-follow-the-green.jpg', alt: 'Guests walking a green rain-fed trail near Breathe Woods' },
        { eyebrow: 'Clearer mornings', title: 'Let the day begin outside.', detail: 'Walk, linger over breakfast and follow the light.', image: 'Pics/optimized/home/hero-morning.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-morning.jpg', alt: 'Morning light over the Breathe Woods garden' },
        { eyebrow: 'Two private villas', title: 'Your place in the woods.', detail: 'A quiet base for a few days among the hills and water.', image: 'Pics/optimized/home/hero-villa.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-villa.jpg', alt: 'A Breathe Woods villa in the rain' },
        { eyebrow: 'A green-season stay', title: 'Make room for time together.', detail: 'Good food, open space and a slower way to spend the day.', image: 'Pics/optimized/home/hero-relax-people.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-relax-people.jpg', alt: 'Two guests sitting with warm drinks on a Breathe Woods porch' }
      ],
      introNote: 'Clearer skies, full green spaces and comfortable days for exploring the property at your own pace.',
      experience: {
        eyebrow: 'After the rains', title: 'The green stays with you.',
        body: 'Take the longer route, linger by the water and enjoy the open space before the year turns cooler.',
        image: 'Pics/optimized/home/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', alt: 'Aerial view of Breathe Woods surrounded by water and forest'
      },
      breakfast: 'Start with a generous, home-style breakfast, then take the morning outside for a walk, a view or a little more time at the table.',
      closing: {
        eyebrow: 'A green-season stay', title: 'Take the long way around.',
        body: 'Choose your dates and enjoy a few days of open space, good food and time together.',
        image: 'Pics/optimized/home/hero-villa.jpg', mobileImage: 'Pics/optimized/home-mobile/hero-villa.jpg', alt: 'A Breathe Woods villa in the rain'
      },
      pages: {
        stays: {
          'stays-hero-eyebrow': 'After the rains at Breathe Woods',
          'stays-hero-title': 'Take the longer way around.',
          'stays-hero-body': 'Two villas, five bedrooms and a property that is at its fullest after the rains.',
          'stays-intro': 'Clearer days, full green spaces and room to explore before the evenings turn cooler.',
          images: { 'stays-hero': { image: 'Pics/optimized/home/hero-drone-1-restored-v1.png_2K_20260930101038.jpg', alt: 'Aerial view of Breathe Woods surrounded by full green space' } }
        },
        property: {
          'property-intro-title': 'The green stays with you.',
          'property-intro-body': 'After the rains, the landscape is full and open. Take the longer route, linger by the water and let the day unfold without hurry.',
          'property-dining-body': 'After a walk around the property, By the Bruk is close by for breakfast, lunch, dinner or another cup of chai.',
          'property-season-eyebrow': 'After the rains',
          'property-season-title': 'Clearer skies, slower evenings.',
          'property-season-body': 'Enjoy the fuller landscape, lake views and open paths while conditions are comfortable. Water outings remain subject to local conditions and on-ground guidance.'
        },
        dining: {
          'dining-hero-eyebrow': 'The green season at By the Bruk',
          'dining-hero-title': 'Good food after a day outside.',
          'dining-hero-body': 'Local flavours, fresh ingredients and a table worth returning to after the walk back.',
          'dining-intro-body': 'By the Bruk is our on-site restaurant, where local Maharashtrian flavours, seasonal ingredients and unhurried meals come together. After the rains, bring the day back to the table and take your time.',
          'dining-evening-title': 'Dinner under clearer skies.',
          'dining-evening-body': 'As the landscape settles after the rains, the lamps come on and dinner becomes an easy end to a day outdoors.'
        },
        explore: {
          'explore-hero-eyebrow': 'Explore after the rains',
          'explore-hero-title': 'The land is ready to wander.',
          'explore-hero-body': 'Take the longer trail, linger by the water and enjoy the open space while the landscape is still full from the rains.',
          'explore-fire-title': 'Stay out a little longer.',
          'explore-fire-body': 'Bonfire and barbecue are paid add-ons, available by advance arrangement and when the weather allows—a good way to end a day outside.',
          images: { 'explore-hero': { image: 'Pics/Explore/bikesbreathewoods.jpg', alt: 'Bicycles ready for a ride through the countryside near Breathe Woods' } }
        },
        information: {
          'information-hero-eyebrow': 'Planning a post-monsoon stay',
          'information-hero-title': 'Come for the green.<br>Stay for the quiet.',
          'information-hero-body': 'Here is the practical part: arrival, meals, fuller landscapes and a rough sense of the journey. Once you are here, the plan can loosen.',
          'information-season-title': 'The landscape is at its fullest.',
          'information-season-body': 'After the rains, enjoy clearer days, full green spaces, walks, lake views and time outdoors. Ask the team what is best on the day.',
          'information-weather-title': 'Comfortable days, changing light.',
          'information-weather-body': 'Bring comfortable walking shoes and a light layer for evenings. Bonfire, barbecue and lake outings remain subject to local conditions and on-ground guidance.',
          'information-packing-title': 'Pack for walking and evenings.',
          'information-packing-body': 'Comfortable shoes, sun protection and a light layer are useful. Bring anything your pet needs; towels and essential toiletries are provided.'
        },
        contact: {
          'contact-hero-eyebrow': 'Post-monsoon enquiries',
          'contact-hero-title': 'Let’s plan<br>your green-season stay.',
          'contact-hero-body': 'Tell us your dates, group and what you would like to make time for: walks, water, meals or simply a few quiet days.',
          'contact-enquiry-title': 'A good stay starts with a simple hello.',
          'contact-enquiry-body': 'Share your preferred dates, group size and whether you would like to ask about meals, outdoor experiences or a pet-friendly stay.'
        }
      }
    }
  }

  function currentSeason() {
    const params = new URLSearchParams(window.location.search)
    const forced = params.get('season')
    if (forced && Object.prototype.hasOwnProperty.call(seasons, forced)) return forced
    if (manualSeason && Object.prototype.hasOwnProperty.call(seasons, manualSeason)) return manualSeason
    const previewDate = params.get('previewDate')
    const isValidPreviewDate = /^\d{4}-\d{2}-\d{2}$/.test(previewDate || '')
    const date = isValidPreviewDate ? new Date(`${previewDate}T12:00:00+05:30`) : new Date()
    const parts = new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', month: 'numeric', day: 'numeric' }).formatToParts(date)
    const month = Number(parts.find((part) => part.type === 'month')?.value)
    const day = Number(parts.find((part) => part.type === 'day')?.value)
    if (month >= 3 && month <= 5) return 'summer'
    if (month >= 6 && month <= 9) return 'monsoon'
    if (month === 10 || (month === 11 && day < 15)) return 'postMonsoon'
    return 'winter'
  }

  function setText(selector, value) {
    const node = document.querySelector(selector)
    if (node && value) node.textContent = value
  }

  function setHero(seasonHero) {
    seasonHero.forEach((scene, index) => {
      const frame = document.querySelector(`.hero-frame[data-scene="${index}"]`)
      if (!frame) return
      const image = frame.querySelector('[data-seasonal-hero-image]')
      if (image) {
        image.src = scene.image
        image.srcset = `${scene.mobileImage} 820w, ${scene.image} 1600w`
        image.alt = scene.alt
      }
      const eyebrow = frame.querySelector('[data-seasonal-hero-eyebrow]')
      const title = frame.querySelector('[data-seasonal-hero-title]')
      const detail = frame.querySelector('[data-seasonal-hero-detail]')
      if (eyebrow) eyebrow.textContent = scene.eyebrow
      if (title) title.textContent = scene.title
      if (detail) {
        detail.textContent = scene.detail
        detail.hidden = !scene.detail
      }
    })
  }

  function setImage(selector, image, mobileImage, alt) {
    const imageNode = document.querySelector(selector)
    if (!imageNode) return
    imageNode.src = image
    if (mobileImage) imageNode.srcset = `${mobileImage} 820w, ${image} 1600w`
    if (alt) imageNode.alt = alt
  }

  function applyPageSeason(pageSeason) {
    if (!pageSeason) return
    for (const [key, value] of Object.entries(pageSeason)) {
      if (key === 'images') continue
      const node = document.querySelector(`[data-seasonal-page="${key}"]`)
      if (node) node.innerHTML = value
    }
    for (const [key, image] of Object.entries(pageSeason.images || {})) {
      const node = document.querySelector(`[data-seasonal-page-image="${key}"]`)
      if (!node) continue
      node.src = image.image
      node.alt = image.alt
    }
  }

  const seasonKey = currentSeason()
  const season = seasons[seasonKey]
  document.documentElement.dataset.season = seasonKey
  setHero(season.hero)
  applyPageSeason(season.pages?.[document.body.dataset.page])
  setText('[data-seasonal="intro-note"]', season.introNote)
  setText('[data-seasonal="experience-eyebrow"]', season.experience.eyebrow)
  setText('[data-seasonal="experience-title"]', season.experience.title)
  setText('[data-seasonal="experience-body"]', season.experience.body)
  setImage('[data-seasonal-image="experience"]', season.experience.image, season.experience.mobileImage, season.experience.alt)
  setText('[data-seasonal="breakfast-body"]', season.breakfast)
  setText('[data-seasonal="closing-eyebrow"]', season.closing.eyebrow)
  setText('[data-seasonal="closing-title"]', season.closing.title)
  setText('[data-seasonal="closing-body"]', season.closing.body)
  setImage('[data-seasonal-image="closing"]', season.closing.image, season.closing.mobileImage, season.closing.alt)
})()
