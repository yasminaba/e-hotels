-- Trigger 1: Prevent booking a room with unresolved problems
DROP TRIGGER IF EXISTS trg_prevent_problematic_booking ON Booking;
DROP FUNCTION IF EXISTS prevent_problematic_booking CASCADE;

CREATE OR REPLACE FUNCTION prevent_problematic_booking() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM RoomProblems
        WHERE HotelID = NEW.HotelID
          AND RoomID = NEW.RoomID
          AND Resolved = FALSE
    ) THEN
        RAISE EXCEPTION '⛔ Cannot book room with unresolved problems.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_problematic_booking
BEFORE INSERT ON Booking
FOR EACH ROW
EXECUTE FUNCTION prevent_problematic_booking();

-- Trigger 2: Enforce max 5 active bookings per customer
DROP TRIGGER IF EXISTS trg_limit_active_bookings ON Booking;
DROP FUNCTION IF EXISTS limit_active_bookings CASCADE;

CREATE OR REPLACE FUNCTION limit_active_bookings() RETURNS TRIGGER AS $$
DECLARE
    active_bookings_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO active_bookings_count
    FROM Booking
    WHERE CustomerID = NEW.CustomerID
      AND Status IN ('Pending', 'Checked-in');

    IF active_bookings_count >= 5 THEN
        RAISE EXCEPTION '❌ Customer already has 5 or more active bookings.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_limit_active_bookings
BEFORE INSERT ON Booking
FOR EACH ROW
EXECUTE FUNCTION limit_active_bookings();

-- Trigger 3: Prevent cancellation on the day of check-in
DROP TRIGGER IF EXISTS trg_prevent_late_cancellation ON Booking;
DROP FUNCTION IF EXISTS prevent_late_cancellation CASCADE;

CREATE OR REPLACE FUNCTION prevent_late_cancellation() RETURNS TRIGGER AS $$
BEGIN
    -- Block cancellation on check-in day
    IF NEW.Status = 'Cancelled'
       AND OLD.Status != 'Cancelled'
       AND NEW.CheckInDate = CURRENT_DATE THEN
        RAISE EXCEPTION '⛔ Cannot cancel a booking on the day of check-in.';
    END IF;

    -- Block cancellation if already checked-in
    IF OLD.Status = 'Checked-in' AND NEW.Status = 'Cancelled' THEN
        RAISE EXCEPTION '⛔ Cannot cancel a booking that has already been checked-in.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_late_cancellation
BEFORE UPDATE ON Booking
FOR EACH ROW
EXECUTE FUNCTION prevent_late_cancellation();

-- Trigger 4: Archive booking before deletion
DROP TRIGGER IF EXISTS trg_archive_booking ON Booking;
DROP FUNCTION IF EXISTS archive_booking CASCADE;

CREATE OR REPLACE FUNCTION archive_booking() RETURNS TRIGGER AS $$
DECLARE
    hotel_name TEXT;
    room_code TEXT;
BEGIN
    SELECT HotelName INTO hotel_name
    FROM Hotel WHERE HotelID = OLD.HotelID;

    room_code := 'Room ' || OLD.RoomID;

    INSERT INTO BookingArchive (
        BookingID, CustomerName, HotelName, RoomIdentifier, 
        BookingDate, CheckInDate, CheckOutDate, Status
    )
    SELECT
        OLD.BookingID,
        c.FullName,
        hotel_name,
        room_code,
        OLD.BookingDate,
        OLD.CheckInDate,
        OLD.CheckOutDate,
        OLD.Status
    FROM Customer c
    WHERE c.CustomerID = OLD.CustomerID;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_archive_booking
BEFORE DELETE ON Booking
FOR EACH ROW
EXECUTE FUNCTION archive_booking();

-- Trigger 5: Archive rental before deletion
DROP TRIGGER IF EXISTS trg_archive_rental ON Rental;
DROP FUNCTION IF EXISTS archive_rental CASCADE;

CREATE OR REPLACE FUNCTION archive_rental() RETURNS TRIGGER AS $$
DECLARE
    hotel_name TEXT;
    employee_name TEXT;
    customer_name TEXT;
    room_code TEXT;
BEGIN
    SELECT HotelName INTO hotel_name
    FROM Hotel WHERE HotelID = OLD.HotelID;

    SELECT FullName INTO employee_name
    FROM Employee WHERE EmployeeID = OLD.EmployeeID;

    SELECT FullName INTO customer_name
    FROM Customer WHERE CustomerID = OLD.CustomerID;

    room_code := 'Room ' || OLD.RoomID;

    INSERT INTO RentalArchive (
        RentalID, CustomerName, HotelName, RoomIdentifier, 
        EmployeeName, BookingID, CheckInDate, CheckOutDate, 
        Status, PaymentAmount, PaymentDate, PaymentMethod
    )
    VALUES (
        OLD.RentalID,
        customer_name,
        hotel_name,
        room_code,
        employee_name,
        OLD.BookingID,
        OLD.CheckInDate,
        OLD.CheckOutDate,
        OLD.Status,
        OLD.PaymentAmount,
        OLD.PaymentDate,
        OLD.PaymentMethod
    );

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_archive_rental
BEFORE DELETE ON Rental
FOR EACH ROW
EXECUTE FUNCTION archive_rental();

-- Trigger 6: Adjust room status based on booking updates (Checked-in → Occupied, Cancelled → Available)
DROP TRIGGER IF EXISTS trg_update_room_status_booking ON Booking;
DROP FUNCTION IF EXISTS update_room_status_booking CASCADE;

CREATE OR REPLACE FUNCTION update_room_status_booking() RETURNS TRIGGER AS $$
BEGIN
    -- When booking becomes Pending → mark room as Booked
    IF NEW.Status = 'Pending' AND (OLD.Status IS DISTINCT FROM 'Pending') THEN
        UPDATE Room
        SET Status = 'Booked'
        WHERE RoomID = NEW.RoomID AND HotelID = NEW.HotelID;

    -- When booking becomes Checked-in → mark room as Occupied
    ELSIF NEW.Status = 'Checked-in' AND (OLD.Status IS DISTINCT FROM 'Checked-in') THEN
        UPDATE Room
        SET Status = 'Occupied'
        WHERE RoomID = NEW.RoomID AND HotelID = NEW.HotelID;

    -- When booking becomes Cancelled → mark room as Available
    ELSIF NEW.Status = 'Cancelled' AND (OLD.Status IS DISTINCT FROM 'Cancelled') THEN
        UPDATE Room
        SET Status = 'Available'
        WHERE RoomID = NEW.RoomID AND HotelID = NEW.HotelID;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_room_status_booking
AFTER INSERT OR UPDATE ON Booking
FOR EACH ROW
EXECUTE FUNCTION update_room_status_booking();

-- Trigger 7: Adjust room status based on rental progress
DROP TRIGGER IF EXISTS trg_update_room_status_rental ON Rental;
DROP FUNCTION IF EXISTS update_room_status_rental CASCADE;

CREATE OR REPLACE FUNCTION update_room_status_rental() RETURNS TRIGGER AS $$
DECLARE
    today DATE := CURRENT_DATE;
BEGIN
    -- If status is not provided or is NULL, infer it
    IF NEW.Status IS NULL THEN
        IF today BETWEEN NEW.CheckInDate AND NEW.CheckOutDate THEN
            NEW.Status := 'Ongoing';
        ELSIF today > NEW.CheckOutDate THEN
            NEW.Status := 'Completed';
        END IF;
    END IF;

    -- Update the room status accordingly
    IF NEW.Status = 'Ongoing' THEN
        UPDATE Room
        SET Status = 'Occupied'
        WHERE RoomID = NEW.RoomID AND HotelID = NEW.HotelID;

    ELSIF NEW.Status = 'Completed' THEN
        UPDATE Room
        SET Status = 'Available'
        WHERE RoomID = NEW.RoomID AND HotelID = NEW.HotelID;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_room_status_rental
AFTER INSERT OR UPDATE ON Rental
FOR EACH ROW
EXECUTE FUNCTION update_room_status_rental();

-- Trigger function to mark booking as Checked-in when rental is created
DROP TRIGGER IF EXISTS trg_mark_booking_checked_in ON Rental;
DROP FUNCTION IF EXISTS mark_booking_checked_in CASCADE;

CREATE OR REPLACE FUNCTION mark_booking_checked_in() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.BookingID IS NOT NULL THEN
        UPDATE Booking
        SET Status = 'Checked-in'
        WHERE BookingID = NEW.BookingID;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_booking_checked_in
AFTER INSERT ON Rental
FOR EACH ROW
EXECUTE FUNCTION mark_booking_checked_in();

-- Trigger function to prevent deletion of rooms that are booked or rented
DROP TRIGGER IF EXISTS trg_prevent_room_deletion ON Room;
DROP FUNCTION IF EXISTS prevent_deleting_active_rooms CASCADE;

CREATE OR REPLACE FUNCTION prevent_deleting_active_rooms() RETURNS TRIGGER AS $$
DECLARE
    room_status TEXT;
BEGIN
    -- Get current room status
    SELECT Status INTO room_status
    FROM Room
    WHERE HotelID = OLD.HotelID AND RoomID = OLD.RoomID;

    -- Only allow deletion if status is 'Available' or 'Out-of-Order'
    IF room_status NOT IN ('Available', 'Out-of-Order') THEN
        RAISE EXCEPTION '❌ Cannot delete room with status "%". Only Available or Out-of-Order rooms can be deleted.', room_status;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_room_deletion
BEFORE DELETE ON Room
FOR EACH ROW
EXECUTE FUNCTION prevent_deleting_active_rooms();

-- Trigger function to set room status to 'Out-of-Order' when a problem is reported and the room is currently available
DROP TRIGGER IF EXISTS trg_mark_out_of_order ON RoomProblems;
DROP FUNCTION IF EXISTS mark_out_of_order_if_available CASCADE;

CREATE OR REPLACE FUNCTION mark_out_of_order_if_available() RETURNS TRIGGER AS $$
BEGIN
    -- Only affect rooms that are currently Available
    IF EXISTS (
        SELECT 1 FROM Room
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID AND Status = 'Available'
    ) THEN
        UPDATE Room
        SET Status = 'Out-of-Order'
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_out_of_order
AFTER INSERT ON RoomProblems
FOR EACH ROW
EXECUTE FUNCTION mark_out_of_order_if_available();

-- Trigger function to restore room status to 'Available' when all problems for the room are resolved
DROP TRIGGER IF EXISTS trg_restore_available_status ON RoomProblems;
DROP FUNCTION IF EXISTS restore_status_if_all_resolved CASCADE;

CREATE OR REPLACE FUNCTION restore_status_if_all_resolved() RETURNS TRIGGER AS $$
DECLARE
    current_status TEXT;
BEGIN
    SELECT Status INTO current_status
    FROM Room
    WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;

    IF current_status = 'Out-of-Order' AND NOT EXISTS (
        SELECT 1 FROM RoomProblems
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID AND Resolved = FALSE
    ) THEN
        UPDATE Room
        SET Status = 'Available'
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_restore_available_status
AFTER UPDATE OF Resolved ON RoomProblems
FOR EACH ROW
WHEN (NEW.Resolved = TRUE)
EXECUTE FUNCTION restore_status_if_all_resolved();

-- Trigger function to mark a room as 'Out-of-Order' when a new problem is reported while it's currently 'Available'
DROP TRIGGER IF EXISTS trg_mark_room_out_of_order ON RoomProblems;
DROP FUNCTION IF EXISTS mark_room_out_of_order CASCADE;

CREATE OR REPLACE FUNCTION mark_room_out_of_order() RETURNS TRIGGER AS $$
DECLARE
    current_status TEXT;
BEGIN
    SELECT Status INTO current_status
    FROM Room
    WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;

    IF current_status = 'Available' THEN
        UPDATE Room
        SET Status = 'Out-of-Order'
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_room_out_of_order
AFTER INSERT ON RoomProblems
FOR EACH ROW
EXECUTE FUNCTION mark_room_out_of_order();

-- Trigger: Restore room status to 'Available' on delete only if status was Out-of-Order
CREATE OR REPLACE FUNCTION restore_status_after_problem_delete() RETURNS TRIGGER AS $$
DECLARE
    current_status TEXT;
    has_unresolved BOOLEAN;
BEGIN
    -- Check if there are unresolved problems for the same room
    SELECT EXISTS (
        SELECT 1 FROM RoomProblems
        WHERE HotelID = OLD.HotelID AND RoomID = OLD.RoomID AND Resolved = FALSE
    ) INTO has_unresolved;

    -- Get the current room status
    SELECT Status INTO current_status
    FROM Room
    WHERE HotelID = OLD.HotelID AND RoomID = OLD.RoomID;

    -- Only update the status to 'Available' if it was 'Out-of-Order' AND there are no more unresolved problems
    IF current_status = 'Out-of-Order' AND NOT has_unresolved THEN
        UPDATE Room
        SET Status = 'Available'
        WHERE HotelID = OLD.HotelID AND RoomID = OLD.RoomID;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_restore_status_on_delete ON RoomProblems;

CREATE TRIGGER trg_restore_status_on_delete
AFTER DELETE ON RoomProblems
FOR EACH ROW
EXECUTE FUNCTION restore_status_after_problem_delete();

-- Trigger function to restrict problem reporting to only Available or Out-of-Order rooms
DROP TRIGGER IF EXISTS trg_restrict_problem_reporting ON RoomProblems;
DROP FUNCTION IF EXISTS restrict_problem_reporting CASCADE;

CREATE OR REPLACE FUNCTION restrict_problem_reporting() RETURNS TRIGGER AS $$
DECLARE
    room_status TEXT;
BEGIN
    SELECT Status INTO room_status
    FROM Room
    WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID;

    IF room_status NOT IN ('Available', 'Out-of-Order') THEN
        RAISE EXCEPTION '❌ You can only report problems for rooms that are Available or Out-of-Order. Current status: %', room_status;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_restrict_problem_reporting
BEFORE INSERT ON RoomProblems
FOR EACH ROW
EXECUTE FUNCTION restrict_problem_reporting();

-- Trigger function to prevent inserting a booking that overlaps with an existing booking or rental
DROP TRIGGER IF EXISTS trg_prevent_overlapping_booking ON Booking;
DROP FUNCTION IF EXISTS prevent_overlapping_booking CASCADE;

CREATE OR REPLACE FUNCTION prevent_overlapping_booking() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM Booking
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID
          AND Status IN ('Pending', 'Checked-in')
          AND (
              NEW.CheckInDate < CheckOutDate AND NEW.CheckOutDate > CheckInDate
          )
    ) OR EXISTS (
        SELECT 1 FROM Rental
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID
          AND (
              NEW.CheckInDate < CheckOutDate AND NEW.CheckOutDate > CheckInDate
          )
    ) THEN
        RAISE EXCEPTION '⛔ Cannot book: Room already booked or rented for selected dates.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_overlapping_booking
BEFORE INSERT ON Booking
FOR EACH ROW
EXECUTE FUNCTION prevent_overlapping_booking();

-- Trigger function to prevent inserting a rental that overlaps with an existing booking or ongoing rental
DROP TRIGGER IF EXISTS trg_prevent_overlapping_rental ON Rental;
DROP FUNCTION IF EXISTS prevent_overlapping_rental CASCADE;

CREATE OR REPLACE FUNCTION prevent_overlapping_rental() RETURNS TRIGGER AS $$
BEGIN
    -- Check for overlapping bookings, excluding the current one if provided
    IF EXISTS (
        SELECT 1 FROM Booking
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID
          AND Status IN ('Pending', 'Checked-in')
          AND (
              NEW.CheckInDate < CheckOutDate AND NEW.CheckOutDate > CheckInDate
          )
          AND (BookingID IS DISTINCT FROM NEW.BookingID)  -- Exclude the one being converted
    ) OR EXISTS (
        SELECT 1 FROM Rental
        WHERE HotelID = NEW.HotelID AND RoomID = NEW.RoomID
          AND Status = 'Ongoing'
          AND (
              NEW.CheckInDate < CheckOutDate AND NEW.CheckOutDate > CheckInDate
          )
    ) THEN
        RAISE EXCEPTION '⛔ Cannot rent: Room already booked or rented for selected dates.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_overlapping_rental
BEFORE INSERT ON Rental
FOR EACH ROW
EXECUTE FUNCTION prevent_overlapping_rental();
