package com.noop.ui

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bottom bar is Home, Health, AI Coach, and More. Sleep and Trends stay reachable from More,
 * and a bar tab is never also a row in that list.
 */
class BottomBarTabsTest {

    private val barTabs = primaryBarTabs

    @Test
    fun noBarTabIsAlsoListedInTheMoreSheet() {
        val inDrawer = drawerGroups.flatMap { it.items }.toSet()
        val both = barTabs.map { it.dest }.filter { it in inDrawer }
        assertTrue("a bar tab must not also appear in the More sheet, found $both", both.isEmpty())
    }

    @Test
    fun theBarCarriesHomeHealthAndCoach() {
        assertEquals(
            listOf(Destination.Today, Destination.Health, Destination.Coach),
            barTabs.map { it.dest },
        )
    }

    @Test
    fun theBarLabelsAreTheExternalizedNavKeys() {
        assertEquals(R.string.nav_bar_home, barTabs[0].labelRes)
        assertEquals(R.string.nav_bar_health, barTabs[1].labelRes)
        assertEquals(R.string.nav_bar_coach, barTabs[2].labelRes)
    }

    @Test
    fun sleepAndTrendsStayReachableFromMore() {
        val inDrawer = drawerGroups.flatMap { it.items }
        assertTrue(Destination.Sleep in inDrawer)
        assertTrue(Destination.Trends in inDrawer)
        assertFalse(Destination.Health in inDrawer)
        assertFalse(Destination.Today in inDrawer)
        assertFalse(Destination.Coach in inDrawer)
    }

    @Test
    fun theBarHasNoDuplicateDestinations() {
        assertEquals(barTabs.map { it.dest }.distinct().size, barTabs.size)
    }

    @Test
    fun everyTabHasALabelResource() {
        assertTrue(barTabs.all { it.labelRes != 0 })
    }
}
